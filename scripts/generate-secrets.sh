#!/usr/bin/env bash
# =============================================================================
# generate-secrets.sh — fill missing secrets in .env (idempotent).
# Generates ONLY empty/absent values; existing ones are kept untouched so
# re-running never invalidates live clients.
#
#   HIDDEN_PATH      random api-like path        e.g. /api/v1/9f3c2a7b/stream
#   SECRET_BASE64    url-safe base64, no padding (xray defense secretId)
#   SECRET_PASSWORD  hex password                (xray defense seed/password)
#   TROJAN_PASSWORD  only when profile=trojan
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

[[ -f "${PROJECT_ROOT}/.env" ]] || die ".env missing — copy .env.example first or run ./install.sh"
load_env

rand_hex()  { openssl rand -hex "${1:-8}"; }
rand_b64u() { openssl rand -base64 24 | tr '+/' '-_' | tr -d '='; }

changed=false

if [[ -z "${HIDDEN_PATH:-}" ]]; then
  # Looks like a plausible REST endpoint, unique per deployment.
  HP="/api/v1/$(rand_hex 4)/stream"
  set_env_var HIDDEN_PATH "$HP"
  info "generated HIDDEN_PATH=${HP}"
  changed=true
else
  info "HIDDEN_PATH already set (${HIDDEN_PATH}) — keeping"
fi

if [[ -z "${SECRET_BASE64:-}" ]]; then
  set_env_var SECRET_BASE64 "$(rand_b64u)"
  info "generated SECRET_BASE64 (value hidden)"
  changed=true
else
  info "SECRET_BASE64 already set — keeping"
fi

if [[ -z "${SECRET_PASSWORD:-}" ]]; then
  set_env_var SECRET_PASSWORD "$(rand_hex 16)"
  info "generated SECRET_PASSWORD (value hidden)"
  changed=true
else
  info "SECRET_PASSWORD already set — keeping"
fi

PROFILE="$(grep -E '^PROFILE=' "${PROJECT_ROOT}/.env" | tail -1 | cut -d= -f2- || true)"
if [[ "${PROFILE:-main}" == "trojan" && -z "${TROJAN_PASSWORD:-}" ]]; then
  set_env_var TROJAN_PASSWORD "$(rand_b64u)"
  info "generated TROJAN_PASSWORD (value hidden)"
  changed=true
fi

# Tighten permissions: .env holds secrets.
chmod 600 "${PROJECT_ROOT}/.env"

if [[ "$changed" == true ]]; then
  info ".env updated and chmod 600 applied"
else
  info "nothing to generate — all secrets present"
fi
