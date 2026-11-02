#!/usr/bin/env bash
# =============================================================================
# renew-hook.sh — certificate lifecycle glue. Called by cron and install.sh.
#
#   ./renew-hook.sh renew         # certbot renew (webroot), redeploy on change
#   ./renew-hook.sh deploy-only   # just copy current certs + reload nginx
#   ./renew-hook.sh renew-now     # force renewal check ignoring age
#
# NO docker.sock inside containers: renewal runs `docker compose run` from the
# host (cron), which is equivalent but keeps the attack surface out of the
# long-running containers. The only privileged action here is reloading nginx,
# done via `docker compose exec` from the host as well.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/common.sh
source "${SCRIPT_DIR}/../scripts/common.sh"
load_env

MODE="${1:-renew}"

deploy() {
  # Copy newest material from the certbot volume into ./nginx/certs, then
  # graceful-reload nginx. Key file contents are never printed.
  bash "${SCRIPT_DIR}/../scripts/render-configs.sh" >/dev/null
  if docker ps --format '{{.Names}}' | grep -q '^vpn-nginx$'; then
    dc exec nginx nginx -t
    dc exec nginx nginx -s reload
    info "nginx reloaded with current certificate"
  else
    warn "nginx container not running — certificates deployed, will load on next start"
  fi
}

case "$MODE" in
  deploy-only)
    deploy
    ;;
  renew|renew-now)
    extra=()
    [[ "${USE_STAGING:-false}" == "true" ]] && extra+=(--staging)
    [[ "$MODE" == "renew-now" ]] && extra+=(--force-renewal)
    dc up -d certbot >/dev/null 2>&1 || true
    say "==> certbot renew for ${DOMAIN}"
    dc run --rm --no-deps certbot \
      renew --webroot -w /var/www/acme \
      --deploy-hook "sh -c 'cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem /etc/letsencrypt/deploy_hint 2>/dev/null || true'" \
      "${extra[@]+"${extra[@]}"}" 2>&1 | sed -E 's/(private key|account key).*$/\1 [redacted]/I' || {
        err "renewal FAILED for ${DOMAIN}. Check: port 80 reachable, DNS still points here, rate limits."
        exit 1
      }
    # certbot kept its state in the named volume; redeploy from there.
    deploy
    info "certificate renewed and deployed"
    ;;
  *)
    die "usage: $0 {renew|renew-now|deploy-only}"
    ;;
esac
