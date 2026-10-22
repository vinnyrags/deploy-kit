#!/bin/bash
# Profile: nextjs — a self-hosted Next.js app on a droplet (e.g. itzenzo.tv), behind
# nginx as a reverse proxy. Checkout, install, build, restart, smoke test. No
# FastCGI/OPcache (that's a PHP concern); Next.js does its own ISR/caching.
#
# Site conf (per-branch maps; see config/site.conf.example):
#   DEPLOY_DIR[b]    app dir (in place)
#   APP_USER[b]      run the build and the app as this user (provision/nextjs-service.sh
#                    creates it and the unit). Without it the build runs as root and
#                    OWNER applies — the old behavior.
#   SYSTEMD_UNIT[b]  unit to restart; PORT[b] the port it listens on (smoke test).
#   POST_DEPLOY[b]   optional script in the repo (e.g. scripts/warm.sh), run as APP_USER
#                    after a passing smoke test with the site's base URL; failures warn only.
#   PM2_APP          legacy: a PM2 app to reload instead of a unit.
# .env* files in the app dir are kept across deploys and locked to 640 root:<APP_USER>.

nextjs_smoke() {  # nextjs_smoke <port> — the app answers on localhost within ~30s
  local port="$1" code=000 i
  for i in $(seq 1 "${SMOKE_TRIES:-15}"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${port}/" || echo 000)"
    case "$code" in 200|301|302|307|308) log "smoke: 127.0.0.1:${port} -> ${code} OK"; return 0 ;; esac
    sleep "${SMOKE_WAIT:-2}"
  done
  echo "============================================" >&2
  log "SMOKE TEST FAILED: 127.0.0.1:${port} returned ${code}" >&2
  log "The code IS deployed (in place) — this is not a rollback. Check: journalctl -u <unit>" >&2
  echo "============================================" >&2
  return 1
}

profile_deploy() {
  local branch="$1" dest="$2" env="$3" user unit port post f
  user="$(conf_map APP_USER "$branch")"
  unit="$(conf_map SYSTEMD_UNIT "$branch")"
  port="$(conf_map PORT "$branch")"
  post="$(conf_map POST_DEPLOY "$branch")"

  checkout_tree "$branch" "$dest"

  log "npm ci + build${user:+ as $user}…"
  if [ -n "$user" ]; then
    chown -R "$user:$user" "$dest"
    runuser -u "$user" -- bash -c "cd '$dest' && npm ci --no-audit --no-fund && npm run build" \
      || { log "build FAILED — nothing restarted, the running app is untouched"; return 1; }
  else
    ( cd "$dest" && npm ci --no-audit --no-fund && npm run build ) \
      || { log "build FAILED — nothing restarted, the running app is untouched"; return 1; }
    own "$dest"
  fi

  for f in "$dest"/.env*; do
    [ -f "$f" ] || continue
    if [ -n "$user" ]; then chown "root:$user" "$f"; chmod 640 "$f"; fi
  done

  if [ -n "${PM2_APP:-}" ]; then
    log "pm2 reload ${PM2_APP}"
    pm2 reload "$PM2_APP" --update-env 2>/dev/null || pm2 restart "$PM2_APP" --update-env
  fi
  if [ -n "$unit" ]; then
    log "systemctl restart ${unit}"
    systemctl restart "$unit"
  fi

  [ -n "$port" ] && { nextjs_smoke "$port" || return 1; }

  if [ -n "$post" ] && [ -f "$dest/$post" ]; then
    local base; base="$(conf_map SITE_URL "$branch")"
    log "post-deploy: $post ${base}"
    if [ -n "$user" ]; then runuser -u "$user" -- bash "$dest/$post" "$base" || log "post-deploy failed (warning only)"
    else bash "$dest/$post" "$base" || log "post-deploy failed (warning only)"; fi
  fi
}
