#!/usr/bin/env bash
# =============================================================================
# backup.sh — single dated archive with everything needed to restore.
#
#   ./backup.sh                 # plain tar.gz into $BACKUP_DIR (from .env)
#   ./backup.sh --encrypt       # + openssl AES-256-CBC (pbkdf2), prompts twice
#   ./backup.sh --quiet         # machine-readable: only final path on stdout
#
# Contents: .env, xray/users.json + rendered config, nginx rendered vhost,
# full project tree (templates/site/scripts), Let's Encrypt material exported
# from the certbot volume, current renewal crontab line.
# The archive contains SECRETS -> dir 0700 / file 0600. Store it OFF-SERVER.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
load_env

QUIET=false; ENCRYPT=false
for a in "$@"; do
  case "$a" in
    --quiet)   QUIET=true ;;
    --encrypt) ENCRYPT=true ;;
    *) die "unknown option '$a' (see header comment)" ;;
  esac
done

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_ROOT}/backups}"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PKG="${WORK}/vpn-docker-backup-${STAMP}"
mkdir -p "${PKG}/config"

quiet() { [[ "$QUIET" == true ]] || say "$*" >&2; }

quiet "==> Collecting configuration and secrets"
cp "${PROJECT_ROOT}/.env"                      "${PKG}/config/env"             2>/dev/null || warn ".env missing"
cp "${PROJECT_ROOT}/xray/users.json"           "${PKG}/config/users.json"      2>/dev/null || warn "users.json missing"
cp "${PROJECT_ROOT}/xray/config.json"          "${PKG}/config/xray-config.json" 2>/dev/null || true
cp "${PROJECT_ROOT}/nginx/conf.d/default.conf" "${PKG}/config/nginx-default.conf" 2>/dev/null || true

quiet "==> Snapshotting project tree (templates, site, scripts)"
tar -cf - -C "${PROJECT_ROOT}" \
    docker-compose.yml install.sh manage.sh update.sh backup.sh restore.sh \
    scripts nginx/nginx.conf nginx/conf.d/default.conf.template nginx/html \
    xray/config.json.template xray/users.example.json certbot tests README.md \
    .env.example .gitignore \
    > "${PKG}/project-tree.tar" 2>/dev/null || true

quiet "==> Exporting Let's Encrypt material (if certbot volume exists)"
if docker volume inspect vpn-docker_certbot-conf >/dev/null 2>&1; then
  mkdir -p "${PKG}/letsencrypt"
  docker run --rm -v vpn-docker_certbot-conf:/le:ro alpine:3.20 \
    tar -cf - -C /le live accounts 2>/dev/null > "${PKG}/letsencrypt/le-volumes.tar" || true
  chmod 600 "${PKG}/letsencrypt/le-volumes.tar" 2>/dev/null || true
fi

crontab -l 2>/dev/null | grep -F 'renew-hook.sh' > "${PKG}/cron.txt" || true

quiet "==> Packing archive"
ARCHIVE="${BACKUP_DIR}/vpn-docker-backup-${STAMP}.tar.gz"
tar -czf "$ARCHIVE" -C "$WORK" "$(basename "$PKG")"
chmod 600 "$ARCHIVE"

if [[ "$ENCRYPT" == true ]]; then
  ENC="${ARCHIVE}.enc"
  read -rs -p "Archive password (openssl AES-256-CBC): " P1; echo >&2
  read -rs -p "Repeat:                                  " P2; echo >&2
  [[ -n "$P1" && "$P1" == "$P2" ]] || die "passwords empty or do not match"
  # Password passed via env fd, never argv, never logged.
  OPENSSL_PASS="$P1" openssl enc -aes-256-cbc -pbkdf2 -salt -in "$ARCHIVE" \
      -out "$ENC" -pass env:OPENSSL_PASS
  unset OPENSSL_PASS
  rm -f "$ARCHIVE"
  ARCHIVE="$ENC"
fi

say "$ARCHIVE"     # stdout = archive path only (parseable by update.sh)
[[ "$QUIET" == true ]] || say "Keep this file off-server: it contains .env, UUIDs and keys." >&2
