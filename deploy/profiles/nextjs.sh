#!/bin/bash
# Profile: nextjs — a self-hosted Next.js app on a droplet (e.g. itzenzo.tv), behind
# nginx as a reverse proxy, run by PM2 or systemd. Checkout, install, build, restart
# the process manager. No FastCGI/OPcache (that's a PHP concern); Next.js does its
# own ISR/caching.
#
# Site conf: DEPLOY_DIR[branch] = app dir; OWNER (e.g. deploy:deploy); one of
# PM2_APP or SYSTEMD_UNIT to restart; optional BUILD_ENV vars.

profile_deploy() {
  local branch="$1" dest="$2" env="$3"
  checkout_tree "$branch" "$dest"

  log "npm ci + build…"
  ( cd "$dest"; npm ci --no-audit --no-fund; npm run build )
  own "$dest"

  if [ -n "${PM2_APP:-}" ]; then
    log "pm2 reload ${PM2_APP}"
    pm2 reload "$PM2_APP" --update-env 2>/dev/null || pm2 restart "$PM2_APP" --update-env
  fi
  if [ -n "${SYSTEMD_UNIT:-}" ]; then
    log "systemctl restart ${SYSTEMD_UNIT}"
    systemctl restart "$SYSTEMD_UNIT"
  fi
}
