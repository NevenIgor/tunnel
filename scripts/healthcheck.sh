#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — diagnose the running stack. Safe to run any time.
# Checks containers, published ports, cert validity/expiry, HTTP->HTTPS
# redirect, site 200, blocked service files, internal websocket reachability,
# recent nginx/xray errors, client-link sanity.
# Exit code: number of failed checks (0 = healthy).
# =============================================================================
set -uo pipefail                       # NOTE: no -e: we want to run ALL checks
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
load_env

FAILS=0
pass() { info "PASS  $*"; }
fail() { err "FAIL  $*"; FAILS=$((FAILS+1)); }
hint() { echo "      ↳ $*" >&2; }

say "==> Healthcheck for ${DOMAIN}"

# 1. Containers up ------------------------------------------------------------
for c in vpn-nginx vpn-xray; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || true)"
  if [[ "$state" == "running" ]]; then pass "container ${c}: running (health=${health})"
  else fail "container ${c} not running (state='${state:-absent}')"; hint "dc up -d && dc logs ${c}"; fi
done

# 2. Only required ports published ----------------------------------------------
PUBLISHED="$(docker port vpn-nginx 2>/dev/null | awk -F: '{print $NF}' | sort -un | tr '\n' ' ')"
if [[ "$PUBLISHED" == *"${HTTP_PORT:-80}"* && "$PUBLISHED" == *"${HTTPS_PORT:-443}"* ]]; then
  pass "nginx publishes ${PUBLISHED}"
else
  fail "unexpected published ports: '${PUBLISHED}'"; hint "expected ${HTTP_PORT:-80} ${HTTPS_PORT:-443}"
fi
if ss -Hltn "( sport = :${XRAY_INTERNAL_PORT:-10000} )" 2>/dev/null | grep -q .; then
  fail "xray port ${XRAY_INTERNAL_PORT} is exposed on the host — it must stay internal!"
else
  pass "xray port ${XRAY_INTERNAL_PORT:-10000} not exposed on host"
fi

# 3. Certificate valid & not expiring --------------------------------------------
if have openssl && [[ -f "${PROJECT_ROOT}/nginx/certs/fullchain.pem" ]]; then
  if openssl x509 -in "${PROJECT_ROOT}/nginx/certs/fullchain.pem" -checkend $((15*86400)) >/dev/null 2>&1; then
    EXP="$(openssl x509 -enddate -noout -in "${PROJECT_ROOT}/nginx/certs/fullchain.pem" | cut -d= -f2)"
    pass "certificate valid, expires ${EXP}"
  else
    fail "certificate expires within 15 days or is invalid"
    hint "run: sudo ./certbot/renew-hook.sh renew-now"
  fi
  if openssl x509 -in "${PROJECT_ROOT}/nginx/certs/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "$DOMAIN"; then
    pass "certificate covers ${DOMAIN}"
  else
    fail "certificate does not cover ${DOMAIN} (SAN mismatch)"
  fi
else
  warn "skipping certificate file checks (no local fullchain.pem)"
fi

# 4. Live HTTPS via curl ------------------------------------------------------------
BASE="https://${DOMAIN}"
CODE="$(curl -fsSk -o /dev/null -w '%{http_code}' --max-time 15 "${BASE}/" 2>/dev/null || true)"
if [[ "$CODE" == "200" ]]; then pass "GET ${BASE}/ -> 200"
else fail "GET ${BASE}/ -> '${CODE:-no response}'"; hint "check DNS, firewall 443, nginx logs"; fi

# 5. HTTP redirects to HTTPS ----------------------------------------------------------
REDIR="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 "http://${DOMAIN}/" 2>/dev/null || true)"
if [[ "$REDIR" == https://"${DOMAIN}"* ]]; then pass "http:// -> redirects to https"
else fail "http:// redirect is wrong/missing ('${REDIR}')"; fi

# 6. Service files not served ---------------------------------------------------------
for probe in "/.env" "/.git/config" "/xray/config.json"; do
  C="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${BASE}${probe}" 2>/dev/null || true)"
  if [[ "$C" == "403" || "$C" == "404" ]]; then pass "blocked ${probe} (${C})"
  else fail "${probe} returned ${C:-timeout} — expected 403/404"; fi
done

# 7. Hidden path reachable through nginx (from inside the stack) ----------------------
WS_CODE="$(docker exec vpn-nginx sh -c "wget -qO /dev/null -S --header='Connection: Upgrade' --header='Upgrade: websocket' -T 5 http://127.0.0.1${HIDDEN_PATH} 2>&1 | awk '/^  HTTP/{print \$2}' | tail -1" 2>/dev/null || true)"
case "$WS_CODE" in
  101|400|405) pass "hidden path proxied to xray (internal status ${WS_CODE})" ;;
  *)           fail "hidden path not reachable internally (status '${WS_CODE:-none}')"; hint "nginx proxy_pass -> xray:${XRAY_INTERNAL_PORT}; check dc ps && dc logs xray" ;;
esac

# 8. Recent errors in logs --------------------------------------------------------
NX="$(dc logs --since 10m nginx 2>/dev/null | grep -Ei '\[(emerg|alert|crit)\]' | tail -3 || true)"
if [[ -n "$NX" ]]; then fail "nginx has emerg/alert/crit logs:"; echo "$NX" >&2; else pass "no critical nginx log entries (last 10m)"; fi
XC="$(dc logs --since 10m xray 2>/dev/null | grep -Ei 'error|failed' | tail -3 || true)"
if [[ -n "$XC" ]]; then warn "xray logged errors (last 10m):"; echo "$XC" >&2; else pass "no xray errors (last 10m)"; fi

# 9. Client link sanity -------------------------------------------------------------
FIRST_USER="$(jq -r '[.users[]|select(.enabled==true)][0].name // empty' "${PROJECT_ROOT}/xray/users.json" 2>/dev/null || true)"
if [[ -n "$FIRST_USER" ]]; then
  LINK="$(bash "${SCRIPT_DIR}/generate-client-links.sh" "$FIRST_USER" 2>/dev/null | head -1)"
  if [[ "$LINK" =~ ^(vless|trojan)://[^@]+@${DOMAIN}:${HTTPS_PORT:-443}\?.*(security=tls|sni=${DOMAIN}).*\#${FIRST_USER// /_} ]]; then
    pass "client link for '${FIRST_USER}' well-formed (UUID hidden here)"
  elif [[ -n "$LINK" ]]; then
    fail "client link regex check failed — inspect manually with ./manage.sh show-link ${FIRST_USER}"
  fi
else
  warn "no enabled users — nothing to validate (./manage.sh add-user phone)"
fi

say "==> Healthcheck finished: ${FAILS} failure(s)"
exit "$FAILS"
