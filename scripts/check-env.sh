#!/usr/bin/env bash
# =============================================================================
# check-env.sh — preflight checks for the whole stack.
# Usage: scripts/check-env.sh [--skip-dns] [--skip-ports]
# Exit 0 = all good; non-zero = problems printed with hints.
# Sourced helpers: common.sh (logging, env loading).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

SKIP_DNS=false
SKIP_PORTS=false
for arg in "$@"; do
  case "$arg" in
    --skip-dns)   SKIP_DNS=true ;;
    --skip-ports) SKIP_PORTS=true ;;
    *) die "unknown option: $arg" ;;
  esac
done

ERRORS=0
ok()   { info "OK:   $*"; }
bad()  { err   "FAIL: $*"; ERRORS=$((ERRORS+1)); }

say "==> Preflight checks"

# --- OS ---------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
  bad "not Linux ($(uname -s)). This project targets Ubuntu/Debian servers."
else
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) ok "OS: ${PRETTY_NAME:-$ID}" ;;
      *)             warn "OS '${ID:-unknown}' is not Ubuntu/Debian — scripts may need adaptation." ;;
    esac
  fi
  # 22.04/24.04 recommendation only; don't fail on other versions.
  if [[ -r /etc/os-release ]] && grep -q 'VERSION_ID="\(20\.04\|18\.04\|16\.04\)"' /etc/os-release; then
    warn "Old Ubuntu LTS detected. 22.04/24.04 recommended."
  fi
fi

# --- Dependencies -------------------------------------------------------------
for bin in docker curl openssl jq python3; do
  if have "$bin"; then ok "found $bin"; else bad "missing dependency: $bin"; fi
done
if have envsubst; then ok "found envsubst (gettext-base)"; else warn "envsubst missing — render-configs.sh will fall back to python3."; fi
if have qrencode; then ok "found qrencode (terminal QR codes)"; else warn "qrencode missing — show-qr will print the raw link only (apt install qrencode)."; fi

# --- Docker + compose v2 --------------------------------------------------------
if docker version >/dev/null 2>&1; then ok "docker daemon reachable"; else bad "docker daemon not reachable (install docker.io and add user to docker group?)"; fi
if compose_cmd version >/dev/null 2>&1; then ok "docker compose v2 present ($(compose_cmd version | head -1))"; else bad "docker compose v2 missing (plugin 'docker-compose-plugin')"; fi

# --- .env / configuration ------------------------------------------------------------
if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
  bad ".env not found. Copy .env.example to .env and edit it (or run ./install.sh)."
else
  load_env
  [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "vpn.example.com" ]] \
    && ok "DOMAIN=${DOMAIN}" \
    || bad "DOMAIN is empty or still the example value — set your real domain in .env"

  [[ "${DOMAIN:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    && ok "DOMAIN syntax looks valid" \
    || bad "DOMAIN '${DOMAIN:-}' does not look like a hostname"

  [[ -n "${ACME_EMAIL:-}" && "${ACME_EMAIL}" == *"@"* ]] \
    && ok "ACME_EMAIL=${ACME_EMAIL}" \
    || bad "ACME_EMAIL missing/invalid (needed for Let's Encrypt)"

  [[ -n "${HIDDEN_PATH:-}" && "${HIDDEN_PATH}" == /* ]] \
    && ok "HIDDEN_PATH=${HIDDEN_PATH}" \
    || bad "HIDDEN_PATH must start with '/' (let install.sh generate it)"

  [[ -n "${SECRET_BASE64:-}" && -n "${SECRET_PASSWORD:-}" ]] \
    && ok "secrets present in .env" \
    || warn "SECRET_BASE64/SECRET_PASSWORD empty — generate-secrets.sh will fill them"
fi

# --- DNS -------------------------------------------------------------------------------
if [[ "${SKIP_DNS}" == true ]]; then
  say "skipping DNS check (--skip-dns)"
elif [[ -n "${DOMAIN:-}" && "${DOMAIN}" != "vpn.example.com" ]]; then
  PUB_IP4="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  RESOLVED="$(getent ahostsv4 "${DOMAIN}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [[ -z "${RESOLVED}" ]]; then
    bad "DNS: '${DOMAIN}' does not resolve. Add an A record pointing at ${PUB_IP4:-<server public IP>} and retry (propagation can take minutes)."
  elif [[ -n "${PUB_IP4}" && " ${RESOLVED} " == *" ${PUB_IP4} "* ]]; then
    ok "DNS: ${DOMAIN} -> ${RESOLVED}(matches this host)"
  else
    warn "DNS: ${DOMAIN} resolves to ${RESOLVED}, but this host's public IPv4 is ${PUB_IP4}."
    warn "     If you are NOT running on the VPS itself, ignore this; otherwise fix the A record."
  fi
fi

# --- Ports 80/443 free (on the host, before first up) ---------------------------------------
if [[ "${SKIP_PORTS}" == true ]]; then
  say "skipping port check (--skip-ports)"
else
  for p in "${HTTP_PORT:-80}" "${HTTPS_PORT:-443}"; do
    if ss -Hltn "( sport = :${p} )" 2>/dev/null | grep -q .; then
      # Allowed exception: our own published stack already listening.
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vpn-nginx$'; then
        ok "port ${p} busy, but by vpn-nginx from this stack (re-install is safe)"
      else
        bad "port ${p} is already used by another process: $(ss -Hltnp "( sport = :${p} )" 2>/dev/null | head -1)"
        echo "     Hint: stop apache/nginx/pihole, or change HTTP_PORT/HTTPS_PORT in .env." >&2
      fi
    else
      ok "port ${p} is free"
    fi
  done
fi

# --- Users file ----------------------------------------------------------------------------
if [[ -f "${PROJECT_ROOT}/xray/users.json" ]]; then
  N_USERS="$(jq '[.users[] | select(.enabled==true)] | length' "${PROJECT_ROOT}/xray/users.json" 2>/dev/null || echo '?')"
  ok "users.json present (${N_USERS} enabled user(s))"
else
  warn "xray/users.json not present yet (created by install.sh / manage.sh)"
fi

say "==> Preflight finished: ${ERRORS} error(s)"
[[ "${ERRORS}" -eq 0 ]] || die "fix the FAIL items above and re-run"
ok "environment looks ready"
