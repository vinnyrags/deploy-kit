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

# --- LAYOUT=releases (deploy/lib/releases.sh hooks) -----------------------------------
# DEPLOY_DIR[b] = <base>/current; the unit's WorkingDirectory is that symlink, so a switch
# plus a restart moves the app. shared/ holds .env.production (640 root:<APP_USER>).
# The release is root-owned and read-only to the app except .next/, which Next writes at
# runtime (regenerated ISR pages, the image cache). node_modules stays: `next start` needs it.

profile_user() { conf_map APP_USER "$1"; }

profile_shared_paths() { printf '%s\n' .env.production; }

profile_build() {
  local rel="$1" branch="$2" user
  user="$(conf_map APP_USER "$branch")"
  [ -n "$user" ] || { log "LAYOUT=releases for nextjs needs APP_USER[$branch]"; return 1; }
  log "npm ci + build as $user…"
  chown -R "$user:$user" "$rel"
  runuser -u "$user" -- bash -c "cd '$rel' && npm ci --no-audit --no-fund && npm run build"
}

profile_finalize() {
  local rel="$1" branch="$2" user
  user="$(conf_map APP_USER "$branch")"
  chown -R root:root "$rel" && chmod -R u=rwX,go=rX "$rel" || return 1
  # a missing .next is profile_check's to report, with a clearer message
  [ -d "$rel/.next" ] && chown -R "$user:$user" "$rel/.next"
  return 0
}

profile_check() { [ -s "$1/.next/BUILD_ID" ] || { log "no .next/BUILD_ID — the build produced nothing"; return 1; }; }

profile_activate() {
  local unit; unit="$(conf_map SYSTEMD_UNIT "$1")"
  [ -n "$unit" ] && { log "systemctl restart ${unit}"; systemctl restart "$unit"; }
  return 0
}

profile_smoke() {
  local port; port="$(conf_map PORT "$1")"
  [ -n "$port" ] || { log "smoke: no PORT[$1], skipped"; return 0; }
  nextjs_smoke "$port"
}

profile_after() {
  local branch="$1" cur="$2" post user base
  post="$(conf_map POST_DEPLOY "$branch")"; user="$(conf_map APP_USER "$branch")"; base="$(conf_map SITE_URL "$branch")"
  [ -n "$post" ] && [ -f "$cur/$post" ] || return 0
  log "post-deploy: $post ${base}"
  runuser -u "$user" -- bash "$cur/$post" "$base"
}
