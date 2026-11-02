#!/usr/bin/env bash
# =============================================================================
# render-configs.sh — turn templates + .env into live configs.
#
#   nginx/conf.d/default.conf.template  -> nginx/conf.d/default.conf
#   xray/config.json.template           -> xray/config.json
#   certbot volumes (or ./nginx/certs)  -> nginx/certs/{fullchain,privkey,chain}.pem
#
# Rendering mechanism: python3 (>=3.8, stdlib only). Chosen over envsubst
# because the xray "clients" array is injected as raw JSON and must be
# validated; python also strips nothing / escapes nothing implicitly.
# The script prefers envsubst for the plain nginx template when available,
# but keeps one code path (python) for correctness — see render() below.
#
# Idempotent: safe to run any time; containers are NOT restarted here
# (use `manage.sh reload` after changing inputs).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

load_env

PROFILE="${PROFILE:-main}"            # main (vless-ws) | trojan (optional profile)
LOG_LEVEL="${LOG_LEVEL:-warning}"
XRAY_INTERNAL_PORT="${XRAY_INTERNAL_PORT:-10000}"

[[ -n "${DOMAIN:-}"       ]] || die "DOMAIN not set in .env"
[[ -n "${HIDDEN_PATH:-}"  ]] || die "HIDDEN_PATH not set — run scripts/generate-secrets.sh"

mkdir -p "${PROJECT_ROOT}/nginx/conf.d" "${PROJECT_ROOT}/nginx/certs"

# --- users -> xray clients array -------------------------------------------------
USERS_FILE="${PROJECT_ROOT}/xray/users.json"
# users.json may contain a "_comment" documentation array (as in
# users.example.json) — drop it before jq processing.
user_jq() { jq 'del(._comment)' "$USERS_FILE"; }
if [[ -f "$USERS_FILE" ]]; then
  CLIENTS_JSON="$(user_jq | jq -c '
    if ("'"${PROFILE}"'" == "trojan")
    then [.users[] | select(.enabled==true) | {password: .uuid, email: .name}]
    else [.users[] | select(.enabled==true) | {id: .uuid, email: .name}]
    end')"
  N="$(user_jq | jq -c '[.users[] | select(.enabled==true)] | length')"
else
  warn "xray/users.json missing — rendering with ZERO users (stack will start, no client can connect yet)"
  CLIENTS_JSON="[]"
  N=0
fi
[[ "$N" -gt 0 ]] || warn "no enabled users found — add one with ./manage.sh add-user <name>"

# --- password field for trojan profile --------------------------------------------
if [[ "$PROFILE" == "trojan" ]]; then
  [[ -n "${TROJAN_PASSWORD:-}" ]] || die "PROFILE=trojan requires TROJAN_PASSWORD in .env (generate-secrets.sh can create it)"
  # For trojan, the per-client shared password lives in clients[]; inbound
  # "password" stays inert.
  INBOUND_PASSWORD="unused"
else
  INBOUND_PASSWORD="unused"
fi

# --- certificate material ------------------------------------------------------------
# Certs live in the certbot named volume. If docker+volume exist, copy from
# there; otherwise fall back to a pre-populated ./nginx/certs (restore.sh uses
# this path). We never print key contents.
ensure_certs() {
  local target_dir="${PROJECT_ROOT}/nginx/certs"
  if docker volume inspect vpn-docker_certbot-conf >/dev/null 2>&1; then
    local src=""
    for d in "live/${DOMAIN}" "live/${DOMAIN}_staging"; do
      if docker run --rm -v vpn-docker_certbot-conf:/c:ro alpine:3.20 \
           test -f "/c/${d}/fullchain.pem" 2>/dev/null; then
        src="$d"; break
      fi
    done
    if [[ -n "$src" ]]; then
      info "copying certificates from certbot volume (${src})"
      docker run --rm \
        -v vpn-docker_certbot-conf:/letsencrypt:ro \
        -v "${target_dir}:/out" \
        alpine:3.20 sh -c '
          cp /letsencrypt/'"$src"'/fullchain.pem /out/fullchain.pem
          cp /letsencrypt/'"$src"'/cert.pem       /out/cert.pem
          cp /letsencrypt/'"$src"'/privkey.pem    /out/privkey.pem
          cp /letsencrypt/'"$src"'/chain.pem      /out/chain.pem
          chmod 600 /out/privkey.pem; chmod 644 /out/fullchain.pem /out/cert.pem /out/chain.pem'
    else
      warn "no LE certificate for ${DOMAIN} found in certbot volume yet"
    fi
  fi
  [[ -f "${target_dir}/fullchain.pem" ]] || warn "nginx/certs/fullchain.pem missing — nginx will fail to start until a certificate is issued (install.sh does that)"
}
ensure_certs

# --- render via python3 (single, auditable code path) ----------------------------------
render() {
  local tpl="$1" out="$2"
  DOMAIN="$DOMAIN" HIDDEN_PATH="$HIDDEN_PATH" XRAY_UPSTREAM="xray:${XRAY_INTERNAL_PORT}" \
  XRAY_INTERNAL_PORT="$XRAY_INTERNAL_PORT" HOST="$DOMAIN" PROTOCOL="$PROFILE" \
  PASSWORD="$INBOUND_PASSWORD" USERS_JSON="$CLIENTS_JSON" LOG_LEVEL="$LOG_LEVEL" \
  python3 - "$tpl" "$out" <<'PY'
import json, os, re, sys
tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, encoding="utf-8") as f:
    text = f.read()

def esc(s):
    # JSON-string escaping because some placeholders are substituted INSIDE
    # string literals of the template (paths, passwords, names).
    return json.dumps(s)[1:-1]

def sub(m):
    key = m.group(1)
    val = os.environ.get(key)
    if val is None:
        raise SystemExit(f"render: placeholder ${{{key}}} has no value (set it in .env)")
    if key == "USERS_JSON":
        return val                      # raw JSON array, must not be escaped
    return esc(val)

# Replace only ${VAR} style placeholders; leave nginx $uri/$host etc. intact.
text = re.sub(r"\$\{([A-Z0-9_]+)\}", sub, text)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

say "==> Rendering nginx vhost"
render "${PROJECT_ROOT}/nginx/conf.d/default.conf.template" \
       "${PROJECT_ROOT}/nginx/conf.d/default.conf"

say "==> Rendering xray config"
render "${PROJECT_ROOT}/xray/config.json.template" \
       "${PROJECT_ROOT}/xray/config.json"

# The template is strict JSON with "_comment" keys, so jq validates directly.
if have jq; then
  jq empty "${PROJECT_ROOT}/xray/config.json" \
    || die "rendered xray/config.json is not valid JSON — check template/users.json"
  info "xray/config.json passes structural JSON validation"
fi

chmod 600 "${PROJECT_ROOT}/xray/config.json" 2>/dev/null || true
say "==> Render complete (run 'manage.sh reload' to apply)"
