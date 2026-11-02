#!/usr/bin/env bash
# =============================================================================
# generate-client-links.sh — build vless:// (or trojan://) links + QR + JSON.
#
# Usage:
#   scripts/generate-client-links.sh <user-name> [--qr] [--json] [--out DIR]
#
# Reads DOMAIN/HIDDEN_PATH/HTTPS_PORT/PROFILE from .env and the user's UUID
# from xray/users.json. Prints the link to stdout ONLY when explicitly asked
# for a single user (this is the sanctioned "explicit output" path where a
# secret may appear in the terminal). Batch mode writes files into clients/
# (gitignored) with 600 permissions instead of printing.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"
load_env

PROFILE="${PROFILE:-main}"
PORT="${HTTPS_PORT:-443}"
NAME="" ; SHOW_QR=false ; SHOW_JSON=false ; OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qr)   SHOW_QR=true ;;
    --json) SHOW_JSON=true ;;
    --out)  OUT_DIR="$2"; shift ;;
    -h|--help)
      echo "Usage: $0 <user-name|--all> [--qr] [--json] [--out DIR]"; exit 0 ;;
    -*)     die "unknown option $1" ;;
    *)      NAME="$1" ;;
  esac
  shift
done

[[ -n "$NAME" ]] || die "usage: $0 <user-name|--all> [--qr] [--json]"
USERS_FILE="${PROJECT_ROOT}/xray/users.json"
[[ -f "$USERS_FILE" ]] || die "users.json missing — add a user first: ./manage.sh add-user <name>"

# --- link builder ---------------------------------------------------------------
# VLESS WS TLS link fields:
#   scheme://uuid@domain:port?encryption=none&security=tls&type=ws&host=..&path=..&sni=..#name
make_link() {
  local uuid="$1" server_name="$2" enc_name="$3"
  local path_q
  # RFC3986-encode the websocket path (leading / is fine unencoded in most
  # clients, but v2rayNG expects %2F-safe values; keep it literal for readability
  # since our paths contain only [A-Za-z0-9/_-]).
  path_q="${HIDDEN_PATH}"
  if [[ "$PROFILE" == "trojan" ]]; then
    printf 'trojan://%s@%s:%s?allowInsecure=false&sni=%s&type=ws&path=%s&host=%s#%s' \
      "$uuid" "$DOMAIN" "$PORT" "$DOMAIN" "$path_q" "$DOMAIN" "$enc_name"
  else
    printf 'vless://%s@%s:%s?encryption=none&security=tls&type=ws&host=%s&path=%s&sni=%s#%s' \
      "$uuid" "$DOMAIN" "$PORT" "$DOMAIN" "$path_q" "$DOMAIN" "$enc_name"
  fi
}

# URL-encode display name (spaces, unicode) for the #fragment.
urlencode_name() {
  python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

emit_one() {
  local name="$1" uuid="$2" enabled="$3"
  if [[ "$enabled" != "true" ]]; then
    warn "user '${name}' is disabled — skipping link"
    return 0
  fi
  local link; link="$(make_link "$uuid" "$name" "$(urlencode_name "$name")")"

  if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
    printf '%s\n' "$link" > "${OUT_DIR}/${name}.txt"
    chmod 600 "${OUT_DIR}/${name}.txt"
    info "wrote ${OUT_DIR}/${name}.txt"
  else
    say "$link"
  fi

  if [[ "$SHOW_QR" == true ]]; then
    if have qrencode; then
      qrencode -t ANSIUTF8 "$link"          # QR in terminal (explicit request)
    else
      warn "qrencode not installed — cannot draw QR (apt install qrencode)"
    fi
  fi

  if [[ "$SHOW_JSON" == true ]]; then
    local jf
    jf="$( [[ -n "$OUT_DIR" ]] && printf '%s/%s.json' "$OUT_DIR" "$name" || printf '/dev/stdout' )"
    python3 - "$PROFILE" "$DOMAIN" "$PORT" "$uuid" "$HIDDEN_PATH" "$name" <<'PY' > "$jf"
import json, sys
proto, domain, port, uuid_, path, name = sys.argv[1:7]
if proto == "trojan":
    outb = {"tag":"proxy","type":"trojan","server":domain,"port":int(port),
            "password":uuid_,"network":"ws","wsOpts":{"path":path,"headers":{"Host":domain}},
            "tls":{"enabled":True,"serverName":domain}}
else:
    outb = {"tag":"proxy","type":"vless","server":domain,"port":int(port),
            "uuid":uuid_,"encryption":"none","network":"ws",
            "wsOpts":{"path":path,"headers":{"Host":domain}},
            "tls":{"enabled":True,"serverName":domain}}
print(json.dumps({"log":{"loglevel":"warning"},"outbounds":[outb]}, indent=2))
PY
    [[ -n "$OUT_DIR" ]] && chmod 600 "$jf" && info "wrote ${jf}"
  fi
}

if [[ "$NAME" == "--all" ]]; then
  while IFS=$'\t' read -r uname uuuid uen; do
    emit_one "$uname" "$uuuid" "$uen"
  done < <(jq -r '.users[] | [.name,.uuid,(.enabled|tostring)] | @tsv' "$USERS_FILE")
  [[ -n "$OUT_DIR" ]] || warn "batch mode without --out prints all links to stdout — pass --out clients/ to write files"
else
  REC="$(jq -c --arg n "$NAME" '.users[] | select(.name==$n)' "$USERS_FILE")"
  [[ -n "$REC" ]] || die "user '${NAME}' not found in users.json (see ./manage.sh list-users)"
  jq -r '[.name,.uuid,(.enabled|tostring)] | @tsv' <<<"$REC" |
    while IFS=$'\t' read -r uname uuuid uen; do emit_one "$uname" "$uuuid" "$uen"; done
fi
