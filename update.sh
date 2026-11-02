#!/usr/bin/env bash
# =============================================================================
# update.sh — controlled, reversible stack update.
#
#   ./update.sh                 # pull pinned images + recreate if changed
#   ./update.sh --to nginx:1.28-alpine NGINX_IMAGE   # bump one pinned image
#   ./update.sh --check         # show current vs latest available tags only
#
# Flow: pre-update backup -> (optional version bump in .env) -> pull ->
#       `docker compose up -d` (recreates only changed services) -> smoke
#       healthcheck -> on failure: automatic rollback to previous .env +
#       re-create from the backup's images -> report.
# Rollback strategy: we keep a timestamped copy of .env and the rendered
# configs inside backups/pre-update-<ts>/; restoring them + `up -d` returns
# the stack to the exact previous configuration (images are still local).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
load_env

MODE="pull"; BUMP_VAR=""; BUMP_TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --to)    BUMP_TO="$2"; shift 2 ;;      # usage: --to <image> <VAR>
    *) die "unknown option '$1' (see header comment)" ;;
  esac
done
# If --to was used, the remaining arg is the env var name
if [[ -n "$BUMP_TO" ]]; then MODE="bump"; BUMP_VAR="${1:-}"; fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
PRE_DIR="${PROJECT_ROOT}/backups/pre-update-${STAMP}"

if [[ "$MODE" == "check" ]]; then
  say "Pinned versions in .env:"
  grep -E '^(NGINX|XRAY|CERTBOT)_IMAGE=' "${PROJECT_ROOT}/.env" || true
  say ""
  say "Current upstream release channels (informational):"
  say "  xray-core : https://github.com/XTLS/Xray-core/releases"
  say "  nginx     : https://hub.docker.com/_/nginx (stable alpine tags)"
  say "  certbot   : https://hub.docker.com/r/certbot/certbot/tags"
  exit 0
fi

say "==> 1/5 Pre-update backup"
bash "${SCRIPT_DIR}/backup.sh" --quiet || die "backup failed — aborting update"
mkdir -p "$PRE_DIR"
cp "${PROJECT_ROOT}/.env" "${PRE_DIR}/env.before"
cp "${PROJECT_ROOT}/xray/users.json" "${PRE_DIR}/users.json" 2>/dev/null || true
cp "${PROJECT_ROOT}/nginx/conf.d/default.conf" "${PRE_DIR}/default.conf" 2>/dev/null || true
info "pre-update state saved to ${PRE_DIR}"

if [[ "$MODE" == "bump" ]]; then
  [[ -n "$BUMP_VAR" ]] || die "usage: ./update.sh --to <image-ref> <ENV_VAR>   e.g. --to nginx:1.28-alpine NGINX_IMAGE"
  [[ "$BUMP_VAR" =~ ^(NGINX_IMAGE|XRAY_IMAGE|CERTBOT_IMAGE)$ ]] || die "only NGINX_IMAGE / XRAY_IMAGE / CERTBOT_IMAGE may be bumped"
  info "setting ${BUMP_VAR}=${BUMP_TO} in .env"
  set_env_var "$BUMP_VAR" "$BUMP_TO"
  load_env
fi

rollback() {
  err "Update verification FAILED — rolling back to ${PRE_DIR}"
  cp "${PRE_DIR}/env.before" "${PROJECT_ROOT}/.env"; chmod 600 "${PROJECT_ROOT}/.env"
  load_env
  bash "${SCRIPT_DIR}/scripts/render-configs.sh" >/dev/null 2>&1 || true
  dc up -d --force-recreate nginx xray >/dev/null 2>&1 || true
  err "Rollback done. Inspect: ./manage.sh status ; your pre-update backup: ${PRE_DIR}"
  exit 1
}

say "==> 2/5 Pull pinned images (${NGINX_IMAGE} | ${XRAY_IMAGE})"
dc pull nginx xray || rollback

say "==> 3/5 Re-render configs and recreate changed containers"
bash "${SCRIPT_DIR}/scripts/render-configs.sh" >/dev/null
dc up -d || rollback

say "==> 4/5 Wait & verify"
sleep 8
if bash "${SCRIPT_DIR}/scripts/healthcheck.sh"; then
  say "==> 5/5 Update OK"
else
  rollback
fi

say ""
say "Versions now running:"
dc ps
say ""
say "If everything works, you can prune old images: docker image prune -f"
