#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore a backup.sh archive onto this (or a fresh) server.
#
#   ./restore.sh backups/vpn-docker-backup-20260101-000000.tar.gz [--encrypt]
#
# Flow: verify archive -> show what will be overwritten -> REQUIRE confirmation
#       -> back up current state first -> extract -> fix permissions ->
#       re-render configs -> docker compose up -d -> healthcheck.
# Encrypted archives (.enc) are decrypted on the fly (prompt for password).
# Nothing is deleted outside the project directory; existing .env/users.json
# are saved to backups/pre-restore-<ts>/ before being replaced.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

ARCHIVE="${1:-}"; ENC=false
[[ "${2:-}" == "--encrypt" ]] && ENC=true
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || die "usage: ./restore.sh <archive.tar.gz|.enc> [--encrypt]"

# --- normalise input into a plain tar.gz in $WORK -----------------------------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PLAIN="${WORK}/backup.tar.gz"
if [[ "$ENC" == true || "$ARCHIVE" == *.enc ]]; then
  read -rs -p "Archive password: " P; echo
  OPENSSL_PASS="$P" openssl enc -d -aes-256-cbc -pbkdf2 -in "$ARCHIVE" \
      -out "$PLAIN" -pass env:OPENSSL_PASS || die "decryption failed (wrong password?)"
  unset OPENSSL_PASS
else
  cp "$ARCHIVE" "$PLAIN"
fi

# --- verify structure ----------------------------------------------------------
ROOTDIR="$(tar -tzf "$PLAIN" | head -1 | cut -d/ -f1)"
for must in "${ROOTDIR}/config/env" "${ROOTDIR}/config/users.json" "${ROOTDIR}/project-tree.tar"; do
  tar -tzf "$PLAIN" "$must" >/dev/null 2>&1 || die "archive is missing ${must} — not a valid vpn-docker backup, refusing to restore"
done
info "archive verified (${ROOTDIR})"

tar -xzf "$PLAIN" -C "$WORK"
PKG="${WORK}/${ROOTDIR}"

# --- show plan -----------------------------------------------------------------
say ""
say "The following files in ${PROJECT_ROOT} WILL BE REPLACED:"
say "  .env  xray/users.json  xray/config.json  nginx/conf.d/default.conf"
say "  project tree (templates/scripts/site) if you pass --full"
say "  certbot volume contents (LE accounts+live certs) if present in archive"
say ""
[[ -f "${PKG}/config/env" ]] && say "Backup's DOMAIN: $(grep -E '^DOMAIN=' "${PKG}/config/env" | cut -d= -f2-)"
confirm "Proceed with restore?" || die "aborted — nothing changed"

# --- safety copy of current state -------------------------------------------------
STAMP="$(date -u +%Y%m%d-%H%M%S)"
PRE="${PROJECT_ROOT}/backups/pre-restore-${STAMP}"
mkdir -p "$PRE"; chmod 700 "$PRE"
for f in .env xray/users.json xray/config.json nginx/conf.d/default.conf; do
  [[ -f "${PROJECT_ROOT}/${f}" ]] && cp "${PROJECT_ROOT}/${f}" "${PRE}/$(basename "$f").before" || true
done
info "current state saved to ${PRE}"

# --- restore config files -----------------------------------------------------------
cp "${PKG}/config/env"               "${PROJECT_ROOT}/.env";              chmod 600 "${PROJECT_ROOT}/.env"
cp "${PKG}/config/users.json"        "${PROJECT_ROOT}/xray/users.json";   chmod 600 "${PROJECT_ROOT}/xray/users.json"
[[ -f "${PKG}/config/xray-config.json"    ]] && cp "${PKG}/config/xray-config.json"    "${PROJECT_ROOT}/xray/config.json"            || true
[[ -f "${PKG}/config/nginx-default.conf"  ]] && cp "${PKG}/config/nginx-default.conf"  "${PROJECT_ROOT}/nginx/conf.d/default.conf"   || true
info "configuration restored"

# --- optional full tree restore -------------------------------------------------------
FULL=false
[[ "${2:-}" == "--full" || "${3:-}" == "--full" ]] && FULL=true
if [[ "$FULL" == true ]] || ! have docker; then
  [[ "$FULL" == true ]] || say "(docker missing — restoring full project tree automatically)"
  tar -xf "${PKG}/project-tree.tar" -C "${PROJECT_ROOT}"
  chmod +x "${PROJECT_ROOT}"/*.sh "${PROJECT_ROOT}"/scripts/*.sh "${PROJECT_ROOT}"/certbot/*.sh "${PROJECT_ROOT}"/tests/*.sh
  info "project tree restored"
fi

# --- LE material ------------------------------------------------------------
if [[ -f "${PKG}/letsencrypt/le-volumes.tar" ]] && have docker; then
  if confirm "Restore Let's Encrypt account+certificates into the certbot volume? (overwrites current certs)"; then
    dc volume create certbot-conf >/dev/null
    docker run --rm -v vpn-docker_certbot-conf:/le -v "${PKG}/letsencrypt:/b:ro" alpine:3.20 \
      sh -c 'rm -rf /le/live /le/accounts && tar -xf /b/le-volumes.tar -C /le'
    info "LE material restored"
  fi
fi

# --- bring stack up --------------------------------------------------------------
load_env
bash "${SCRIPT_DIR}/scripts/render-configs.sh"
dc up -d
sleep 5
bash "${SCRIPT_DIR}/scripts/healthcheck.sh" || warn "healthcheck reported issues after restore"

say ""
say "Restore complete. If DNS/firewall now point elsewhere, re-run ./install.sh"
say "to obtain a fresh certificate for the new environment."
