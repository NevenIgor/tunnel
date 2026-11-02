#!/usr/bin/env bash
# =============================================================================
# install.sh — one-shot, idempotent installer for the VPN-fronting stack.
#
#   sudo ./install.sh --domain example.com --email you@example.com [--staging]
#   sudo ./install.sh                # re-run: safe, only fills gaps / renews
#
# Steps: preflight -> deps (with confirmation) -> .env -> secrets -> users ->
#        render -> compose up -> TLS cert (webroot) -> re-render certs ->
#        reload -> healthcheck -> show next steps.
# Never destroys existing data; refuses to overwrite an existing .env unless
# explicitly confirmed.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

ARGS_DOMAIN="" ; ARGS_EMAIL="" ; STAGING=false ; ASSUME_YES=false
usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]
  --domain DOMAIN     public domain with A record pointing here
  --email EMAIL       Let's Encrypt contact email
  --staging           use LE staging CA (rate-limit friendly, untrusted cert)
  -y, --yes           non-interactive: assume yes for dependency install prompts
  -h, --help          this help
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) ARGS_DOMAIN="$2"; shift 2 ;;
    --email)  ARGS_EMAIL="$2";  shift 2 ;;
    --staging) STAGING=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac
done

say "=============================================================="
say " vpn-docker installer (Nginx + Xray VLESS/WS/TLS fallback site)"
say "=============================================================="

# ---------------------------------------------------------------- 1. preflight
if [[ "$(uname -s)" != "Linux" ]]; then
  die "installer must run on the Linux VPS itself (found $(uname -s))."
fi
require_root_or_docker

# ---------------------------------------------------------------- 2. docker?
need_apt=false
if ! have docker; then need_apt=true; fi
if have docker && ! docker compose version >/dev/null 2>&1; then need_apt=true; fi

if [[ "$need_apt" == true ]]; then
  say ""
  say "Docker and/or the Compose v2 plugin are missing."
  if [[ "$ASSUME_YES" != true ]] && ! confirm "Install them now via apt (docker.io + docker-compose-plugin + gettext-base + jq + qrencode)?"; then
    die "aborting: install Docker manually first (https://docs.docker.com/engine/install/ubuntu/) or re-run with -y"
  fi
  export DEBIAN_FRONTEND=noninteractive
  SUDO=""; [[ "$(id -u)" != "0" ]] && SUDO="sudo"
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl gnupg \
      docker.io docker-compose-plugin gettext-base jq qrencode openssl python3
  $SUDO systemctl enable --now docker || true
  info "Docker installed"
fi

for b in jq openssl python3 curl envsubst; do
  have "$b" || die "missing tool '$b'. Install it (apt-get install -y jq openssl python3 curl gettext-base) and retry."
done

# ---------------------------------------------------------------- 3. .env
cd "$PROJECT_ROOT"
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  info "created .env from .env.example"
fi

# Apply CLI overrides into .env (only when provided).
if [[ -n "$ARGS_DOMAIN" ]]; then set_env_var DOMAIN "$ARGS_DOMAIN"; fi
if [[ -n "$ARGS_EMAIL"  ]]; then set_env_var ACME_EMAIL "$ARGS_EMAIL"; fi
if [[ "$STAGING" == true ]]; then set_env_var USE_STAGING true; fi
load_env

if [[ -z "${DOMAIN:-}" || "${DOMAIN}" == "vpn.example.com" ]]; then
  die "DOMAIN is not configured. Re-run with --domain your.tld or edit .env"
fi
if [[ -z "${ACME_EMAIL:-}" || "${ACME_EMAIL}" == "admin@example.com" ]]; then
  die "ACME_EMAIL is not configured. Re-run with --email you@example.com or edit .env"
fi

# Directories that must exist before bind mounts are used.
mkdir -p nginx/conf.d nginx/certs xray clients backups
chmod 700 clients

# ---------------------------------------------------------------- 4. secrets
bash scripts/generate-secrets.sh

# ---------------------------------------------------------------- 5. users file
if [[ ! -f xray/users.json ]]; then
  echo '{"users": []}' > xray/users.json
  chmod 600 xray/users.json
  info "created empty xray/users.json"
else
  info "keeping existing xray/users.json ($(jq '.users|length' xray/users.json) user(s))"
fi

# ---------------------------------------------------------------- 6. preflight checks
# DNS + ports are checked live here; check-env gives the detailed report.
say ""
say "==> Running environment preflight"
bash scripts/check-env.sh --skip-ports || true   # ports may be busy from our own prior run
if [[ "$(docker ps -q -f name=vpn-nginx | wc -l)" == "0" ]]; then
  for p in "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}"; do
    if ss -Hltn "( sport = :${p} )" | grep -q .; then
      die "port ${p} is occupied by a foreign process — free it or change HTTP_PORT/HTTPS_PORT in .env"
    fi
  done
fi

# ---------------------------------------------------------------- 7. bring up stack (no certs yet -> self-signed bootstrap)
if [[ ! -f nginx/certs/fullchain.pem ]]; then
  info "no local certificate yet — generating temporary self-signed bootstrap cert"
  info "(it is replaced by the real Let's Encrypt cert below; nginx needs *a* cert to start and answer ACME)"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout nginx/certs/privkey.pem -out nginx/certs/fullchain.pem \
    -days 1 -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1
  cp nginx/certs/fullchain.pem nginx/certs/cert.pem
  openssl x509 -in nginx/certs/fullchain.pem -noout -text >/dev/null 2>&1 && \
    awk '/BEGIN CERTIFICATE/{c++} c==1' nginx/certs/fullchain.pem > nginx/certs/chain.pem || true
  chmod 600 nginx/certs/privkey.pem
fi

bash scripts/render-configs.sh
dc up -d
info "stack started (bootstrap mode); waiting for nginx to accept ACME requests"
sleep 3

# ---------------------------------------------------------------- 8. certificate
ensure_certbot_volume() { dc up -d certbot >/dev/null 2>&1 || true; }

issue_cert() {
  local extra=()
  [[ "${USE_STAGING:-false}" == "true" ]] && extra+=(--staging)
  say "==> Requesting Let's Encrypt certificate for ${DOMAIN} ($([[ "${USE_STAGING:-false}" == "true" ]] && echo staging || echo production)"
  ensure_certbot_volume
  # webroot method: challenge files land in shared volume `certbot-www`,
  # which nginx serves at /.well-known/acme-challenge/. No docker.sock needed.
  if ! dc run --rm --no-deps certbot \
      certonly --webroot -w /var/www/acme \
      -d "${DOMAIN}" \
      --email "${ACME_EMAIL}" --agree-tos --no-eff-email \
      --keep-until-expiring "${extra[@]+"${extra[@]}"}"; then
    err "Let's Encrypt issuance FAILED. Common causes:"
    err "  * DNS: 'dig +short ${DOMAIN}' must return this server's public IP"
    err "  * Firewall/cloud panel: inbound TCP 80 must reach this host"
    err "  * Rate limits: retry later or run with --staging while testing"
    err "  * Stale account key after email change: add '--register-unsafely-without-email' or remove /etc/letsencrypt/accounts"
    die "certificate not obtained — aborting installation (stack left running with self-signed bootstrap)"
  fi
}

issue_cert

# ---------------------------------------------------------------- 9. deploy real cert & reload
bash scripts/render-configs.sh          # copies LE certs into nginx/certs
dc exec nginx nginx -t                   # fail fast on broken config
bash certbot/renew-hook.sh deploy-only   # nginx reload with new material (idempotent)

# ---------------------------------------------------------------- 10. verify
say ""
bash scripts/healthcheck.sh || warn "healthcheck reported issues — review output above"

# ---------------------------------------------------------------- 11. renewal cron
say "==> Configuring automatic certificate renewal (cron, daily)"
CRON_LINE="0 3 * * * ${PROJECT_ROOT}/certbot/renew-hook.sh renew >> ${PROJECT_ROOT}/backups/renew.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "renew-hook.sh renew"; then
  info "renewal cron already installed — leaving as is"
else
  if [[ "$(id -u)" == "0" ]] || [[ "$ASSUME_YES" == true ]] || confirm "Install a root crontab entry for daily certificate renewal?"; then
    ( crontab -l 2>/dev/null | grep -vF "renew-hook.sh renew" ; echo "$CRON_LINE" ) | crontab -
    info "cron installed: ${CRON_LINE}"
  else
    warn "skipped cron — renew manually with: sudo ${PROJECT_ROOT}/certbot/renew-hook.sh renew"
  fi
fi

# ---------------------------------------------------------------- 12. summary
FIRST_USER_HINT="./manage.sh add-user phone && ./manage.sh show-link phone"
say ""
say "=============================================================="
say " Installation complete."
say "   Site:      https://${DOMAIN}/            (fallback website)"
say "   Endpoint:  wss://${DOMAIN}:${HTTPS_PORT:-443}${HIDDEN_PATH}  (proxied to Xray)"
say "   Profile:   ${PROFILE:-main} (VLESS over WebSocket over TLS)"
say ""
say " Next steps:"
say "   1) Add a user:     ./manage.sh add-user phone"
say "   2) Get its link:   ./manage.sh show-link phone"
say "   3) QR code:        ./manage.sh show-qr phone"
say "   4) Status:         ./manage.sh status   /  scripts/healthcheck.sh"
say " =============================================================="
