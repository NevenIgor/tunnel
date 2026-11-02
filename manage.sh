#!/usr/bin/env bash
# =============================================================================
# manage.sh — day-to-day operations for the stack.
#
#   ./manage.sh add-user <name>       generate UUID, render, reload xray
#   ./manage.sh remove-user <name>    drop user (asks confirmation), reload
#   ./manage.sh list-users            name/uuid/enabled/created table
#   ./manage.sh show-link <name>      print vless:// link (explicit secret out)
#   ./manage.sh show-qr <name>        same link as QR in terminal
#   ./manage.sh export-links [--json] write all links into clients/ (0600)
#   ./manage.sh rotate-user <name>    new UUID for existing name, reload
#   ./manage.sh disable-user <name>   keep record, exclude from live config
#   ./manage.sh enable-user <name>
#   ./manage.sh status                compose ps + healthcheck summary
#   ./manage.sh logs [svc]            tail container logs (default: all)
#   ./manage.sh restart               docker compose restart
#   ./manage.sh reload                re-render configs + graceful apply
#
# Applying user changes: xray is restarted via `docker compose up -d
# --force-recreate xray` (NOT a SIGHUP graceful reload). Rationale: the
# bind-mounted config.json is fully regenerated; recreating one small
# container takes ~1s and briefly drops active tunnels only — acceptable for
# a personal server and far simpler/more reliable than wiring xray's API-based
# reload. Documented in README.md. Nginx is never restarted on user changes,
# so the public website stays online.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"
load_env

USERS_FILE="${PROJECT_ROOT}/xray/users.json"

users_init() { [[ -f "$USERS_FILE" ]] || { echo '{"users": []}' > "$USERS_FILE"; chmod 600 "$USERS_FILE"; }; }
require_user() {
  users_init
  jq -e --arg n "$1" '.users[] | select(.name==$n)' "$USERS_FILE" >/dev/null \
    || die "user '$1' not found (./manage.sh list-users)"
}
mask_uuid() { sed -E 's/^([0-9a-f]{4})[0-9a-f-]+$/\1...masked/' <<<"$1"; }
new_uuid() { python3 -c 'import uuid;print(uuid.uuid4())'; }

write_users() {  # atomically replace users file with content from stdin
  cat > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE" && chmod 600 "$USERS_FILE"
}

apply_and_reload() {
  bash "${SCRIPT_DIR}/scripts/render-configs.sh"
  dc up -d --force-recreate xray >/dev/null
  info "xray restarted with new config (active tunnels dropped for ~1s)"
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  add-user)
    name="${1:?usage: manage.sh add-user <name>}"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "name must be [A-Za-z0-9_-], max 32 chars"
    users_init
    if jq -e --arg n "$name" '.users[] | select(.name==$n)' "$USERS_FILE" >/dev/null; then
      die "user '$name' already exists — use rotate-user to replace its UUID"
    fi
    uuid="$(new_uuid)"; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg n "$name" --arg u "$uuid" --arg t "$ts" \
       '.users += [{name:$n, uuid:$u, enabled:true, created_at:$t}]' \
       "$USERS_FILE" | write_users
    info "added user '$name' (uuid $(mask_uuid "$uuid"))"
    apply_and_reload
    say ""
    say "Client link (handle like a password):"
    bash "${SCRIPT_DIR}/scripts/generate-client-links.sh" "$name"
    ;;

  remove-user)
    name="${1:?usage: manage.sh remove-user <name>}"
    require_user "$name"
    confirm "Really remove user '$name'? Its link stops working immediately." || die "aborted"
    jq --arg n "$name" 'del(.users[] | select(.name==$n))' "$USERS_FILE" | write_users
    rm -f "${PROJECT_ROOT}/clients/${name}.txt" "${PROJECT_ROOT}/clients/${name}.json"
    info "removed user '$name'"
    apply_and_reload
    ;;

  list-users)
    users_init
    printf '%-20s %-38s %-8s %s\n' NAME UUID ENABLED CREATED
    jq -r '.users[] | [.name, .uuid, (.enabled|tostring), .created_at] | @tsv' "$USERS_FILE" |
      while IFS=$'\t' read -r n u e t; do printf '%-20s %-38s %-8s %s\n' "$n" "$u" "$e" "$t"; done
    say "(UUIDs are secrets — this command is the explicit admin view)"
    ;;

  show-link)
    name="${1:?usage: manage.sh show-link <name>}"
    bash "${SCRIPT_DIR}/scripts/generate-client-links.sh" "$name"
    ;;

  show-qr)
    name="${1:?usage: manage.sh show-qr <name>}"
    bash "${SCRIPT_DIR}/scripts/generate-client-links.sh" "$name" --qr
    ;;

  export-links)
    bash "${SCRIPT_DIR}/scripts/generate-client-links.sh" --all --out "${PROJECT_ROOT}/clients" "$@"
    info "links written to clients/<name>.txt (chmod 600, gitignored)"
    ;;

  rotate-user)
    name="${1:?usage: manage.sh rotate-user <name>}"
    require_user "$name"
    uuid="$(new_uuid)"
    jq --arg n "$name" --arg u "$uuid" '(.users[] | select(.name==$n)).uuid = $u' \
       "$USERS_FILE" | write_users
    info "rotated UUID for '$name' -> $(mask_uuid "$uuid"); the old link is dead now"
    apply_and_reload
    say "New link:"
    bash "${SCRIPT_DIR}/scripts/generate-client-links.sh" "$name"
    ;;

  disable-user)
    name="${1:?usage: manage.sh disable-user <name>}"
    require_user "$name"
    jq --arg n "$name" '(.users[] | select(.name==$n)).enabled = false' "$USERS_FILE" | write_users
    apply_and_reload
    info "user '$name' disabled (record kept in users.json)"
    ;;

  enable-user)
    name="${1:?usage: manage.sh enable-user <name>}"
    require_user "$name"
    jq --arg n "$name" '(.users[] | select(.name==$n)).enabled = true' "$USERS_FILE" | write_users
    apply_and_reload
    info "user '$name' enabled"
    ;;

  status)
    dc ps
    say ""
    bash "${SCRIPT_DIR}/scripts/healthcheck.sh" || warn "healthcheck reported failures above"
    ;;

  logs)
    svc="${1:-}"
    if [[ -n "$svc" ]]; then dc logs --tail=100 -f "$svc"; else dc logs --tail=50 -f; fi
    ;;

  restart)
    dc restart
    info "stack restarted"
    dc ps
    ;;

  reload)
    bash "${SCRIPT_DIR}/scripts/render-configs.sh"
    dc exec nginx nginx -t
    dc exec nginx nginx -s reload
    dc up -d --force-recreate xray >/dev/null
    info "nginx reloaded gracefully; xray recreated (~1s tunnel drop)"
    ;;

  help)
    sed -n '3,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;

  *)
    err "unknown command: $cmd"
    sed -n '3,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
