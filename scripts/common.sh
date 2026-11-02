#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers, sourced (never executed) by the other scripts.
# Provides: logging, PROJECT_ROOT, env loading (.env), compose command, prompts.
# =============================================================================

# --- Logging (colours only on a TTY) -----------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_OFF=""
fi
say()  { printf '%s\n'       "$*"; }
info() { printf '%sINFO%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%sWARN%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- Project layout ------------------------------------------------------------
# Resolve to the project root regardless of where the script is called from.
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"

# --- docker compose v2 -------------------------------------------------------------
# Prefer the plugin; fall back to standalone `docker-compose` only if it is v2.
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif have docker-compose && docker-compose version 2>/dev/null | grep -q '^Docker Compose version v2'; then
    docker-compose "$@"
  else
    die "docker compose v2 not found. Install the 'docker-compose-plugin' package."
  fi
}

# Run compose from the project root even when cwd differs.
dc() { (cd "${PROJECT_ROOT}" && compose_cmd "$@"); }

# --- .env handling -----------------------------------------------------------------
# load_env: export variables from .env into the current shell.
# Values are taken literally (no shell expansion) — safe for secrets.
load_env() {
  local envfile="${PROJECT_ROOT}/.env"
  [[ -f "$envfile" ]] || die ".env not found at ${envfile}. Run ./install.sh first."
  set -a
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$envfile")
  set +a
}

# set_env_var KEY VALUE — update-or-append KEY in .env without touching comments.
set_env_var() {
  local key="$1" val="$2" envfile="${PROJECT_ROOT}/.env"
  [[ -f "$envfile" ]] || touch "$envfile"
  if grep -qE "^${key}=" "$envfile"; then
    # Use | as sed delimiter: values may contain / (paths, base64).
    sed -i -E "s|^${key}=.*|${key}=${val}|" "$envfile"
  else
    printf '%s=%s\n' "$key" "$val" >>"$envfile"
  fi
}

# --- Prompts -------------------------------------------------------------------------
confirm() {
  # confirm "question" -> 0 if yes, 1 otherwise. Non-TTY defaults to NO (safe).
  local q="$1" ans
  if [[ ! -t 0 ]]; then return 1; fi
  read -r -p "${q} [y/N] " ans
  [[ "$ans" =~ ^([yY][eE][sS]|[yY])$ ]]
}

require_root_or_docker() {
  # Scripts need docker access; running install as root is fine, otherwise the
  # user must be in the docker group.
  if [[ "$(id -u)" == "0" ]]; then return 0; fi
  if groups | tr ' ' '\n' | grep -qx docker; then return 0; fi
  die "run as root or add your user to the 'docker' group: sudo usermod -aG docker \$USER && newgrp docker"
}
