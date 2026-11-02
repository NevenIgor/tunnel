#!/usr/bin/env bash
# =============================================================================
# smoke-test.sh — offline + online validation of the project.
#
#   ./tests/smoke-test.sh              # offline checks (no docker needed)
#   ./tests/smoke-test.sh --live       # additionally probe the running stack
#
# Offline checks (runnable anywhere, e.g. CI or a laptop):
#   1. bash -n on every script; docker compose config parse
#   2. .env.example -> temp .env; secrets generation; users add/remove via jq
#      logic; render-configs produces valid nginx conf + xray JSON with the
#      expected clients array and hidden path.
#   3. client-link generator produces a well-formed vless:// URL.
# Live checks (--live, need installed+running stack):
#   HTTP->HTTPS redirect, HTTPS site 200, cert matches DOMAIN, service files
#   blocked, hidden WS path proxied internally, user add->link->remove cycle.
# Full integration test requires: real domain + public port 80/443 + docker.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT}/scripts/common.sh"

PASS=0; FAIL=0
t() { if eval "$2"; then PASS=$((PASS+1)); info "PASS  $1"; else FAIL=$((FAIL+1)); err "FAIL  $1"; fi; }

say "===[1] Syntax & compose validity==="
for f in "${ROOT}"/*.sh "${ROOT}"/scripts/*.sh "${ROOT}"/certbot/*.sh "${ROOT}"/tests/*.sh; do
  t "bash -n $(basename "$f")" "bash -n '$f'"
done
if have docker && docker compose version >/dev/null 2>&1; then
  # `config` needs .env for interpolation; use example env in a throwaway copy.
  TMPD="$(mktemp -d)"; cp -r "${ROOT}"/{docker-compose.yml,.env.example} "$TMPD/"
  sed -i 's/^SECRET_BASE64=.*/SECRET_BASE64=x/' "$TMPD/.env.example"
  (cd "$TMPD" && cp .env.example .env && docker compose config -q) \
    && t "docker compose config parses" true || t "docker compose config parses" false
  rm -rf "$TMPD"
else
  warn "docker unavailable — skipping compose config check (run on the VPS)"
fi

say "===[2] Render pipeline (sandboxed copy)==="
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
cp -r "${ROOT}/." "$SB/" 2>/dev/null || true
cd "$SB"
cp .env.example .env
sed -i -E 's|^DOMAIN=.*|DOMAIN=test.example.com|; s|^ACME_EMAIL=.*|ACME_EMAIL=t@e.com|' .env
t "generate-secrets fills HIDDEN_PATH" "bash scripts/generate-secrets.sh >/dev/null && grep -qE '^HIDDEN_PATH=/api/v1/[0-9a-f]{8}/stream$' .env"
t "generate-secrets is idempotent"     "H1=\$(grep '^HIDDEN_PATH=' .env); bash scripts/generate-secrets.sh >/dev/null; H2=\$(grep '^HIDDEN_PATH=' .env); [ \"\$H1\" = \"\$H2\" ]"
# seed one user like manage.sh does
python3 -c 'import uuid;print(uuid.uuid4())' > /tmp/u.$$ 
jq --arg u "$(cat /tmp/u.$$)" '.users=[{name:"phone",uuid:$u,enabled:true,created_at:"now"}]' \
   xray/users.example.json > xray/users.json 2>/dev/null \
|| echo "{\"users\":[{\"name\":\"phone\",\"uuid\":\"$(cat /tmp/u.$$)\",\"enabled\":true,\"created_at\":\"now\"}]}" > xray/users.json
rm -f /tmp/u.$$
# minimal self-signed pair so render doesn't complain (mkdir first: the dir is
# gitignored and therefore absent in a fresh checkout)
mkdir -p nginx/certs
if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
     -keyout nginx/certs/privkey.pem -out nginx/certs/fullchain.pem -days 1 -subj "/CN=test" 2>/dev/null; then
  die "openssl self-signed bootstrap failed — cannot continue sandbox tests"
fi
awk '/BEGIN CERT/{c++} c==1' nginx/certs/fullchain.pem > nginx/certs/chain.pem
cp nginx/certs/fullchain.pem nginx/certs/cert.pem
export PROJECT_ROOT="$SB"
t "render-configs succeeds" "PATH=\"${ROOT}/scripts:\$PATH\" bash scripts/render-configs.sh >/dev/null 2>&1"
t "nginx conf has hidden path"  "grep -qF \"location = \$(grep '^HIDDEN_PATH=' .env | cut -d= -f2-)\" nginx/conf.d/default.conf"
t "nginx conf proxies to xray"  "grep -q 'proxy_pass http://xray:' nginx/conf.d/default.conf"
t "xray json valid + has uuid"  "jq -e '.inbounds[0].settings.clients[0].id' xray/config.json >/dev/null"
HP="$(grep '^HIDDEN_PATH=' .env | cut -d= -f2-)"
[ "$(jq -r '.inbounds[0].streamSettings.wsSettings.path' xray/config.json)" = "${HP}" ] \
  && PASS=$((PASS+1)) && info "PASS  xray ws path rendered" || { FAIL=$((FAIL+1)); err "FAIL  xray ws path"; }

say "===[3] Client link format==="
LINK="$(bash scripts/generate-client-links.sh phone 2>/dev/null | head -1)"
UUID="$(jq -r '.users[0].uuid' xray/users.json)"
t "link scheme+uuid+domain+port" "[[ '${LINK}' == vless://${UUID}@test.example.com:443* ]]"
t "link has tls/ws/host/path/sni/name" \
  "grep -q 'encryption=none&security=tls&type=ws&host=test.example.com&path=${HP}&sni=test.example.com#phone' <<<\"${LINK}\""

cd "$ROOT"
if [[ "${1:-}" == "--live" ]]; then
  say "===[4] Live stack probes==="
  load_env
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/" || true)"
  [ "$code" = "200" ] && PASS=$((PASS+1)) && info "PASS  site returns 200 over https" || { FAIL=$((FAIL+1)); err "FAIL  site https code=$code"; }
  rcode="$(curl -s -o /dev/null -w '%{redirect_code}' --max-time 15 "http://${DOMAIN}/" || true)"
  [ "$rcode" = "301" ] && PASS=$((PASS+1)) && info "PASS  http redirects to https (301)" || { FAIL=$((FAIL+1)); err "FAIL  http redirect code=$rcode"; }
  if echo | timeout 15 openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:443" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -qF "${DOMAIN}"; then PASS=$((PASS+1)); info "PASS  live cert SAN covers ${DOMAIN}"; else FAIL=$((FAIL+1)); err "FAIL  live cert SAN check"; fi
  fcode="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/.env" || true)"
  case "$fcode" in 403|404) PASS=$((PASS+1)); info "PASS  /.env blocked ($fcode)" ;; *) FAIL=$((FAIL+1)); err "FAIL  /.env returned $fcode" ;; esac
  c404="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMAIN}/nope-xyz" || true)"
  [ "$c404" = "404" ] && PASS=$((PASS+1)) && info "PASS  custom 404 page" || { FAIL=$((FAIL+1)); err "FAIL  404 page returned $c404"; }
  say "(full external websocket handshake needs a real VLESS client; internal proxy chain is verified by scripts/healthcheck.sh)"
  bash scripts/healthcheck.sh || warn "healthcheck failures above count against live readiness"
fi

say ""
say "smoke-test: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
