#!/bin/bash
# deploy-kit — shared helpers, sourced by deploy.sh and the profiles.
# Requires bash 4.3+ (namerefs). Ubuntu 24.04 ships bash 5.

log() { echo ">> $*"; }

# conf_map ARRAY_NAME KEY  ->  value of an associative array defined in the site conf.
# e.g. conf_map DEPLOY_DIR main
conf_map() {
  local -n _m="$1"
  printf '%s' "${_m[$2]:-}"
}

# Check out a branch from the bare repo ($BARE) into a work tree, creating it.
checkout_tree() {
  local branch="$1" dest="$2"
  mkdir -p "$dest"
  git --git-dir="$BARE" --work-tree="$dest" checkout -f "$branch"
}

# git clean, scoped, from the bare repo into a work tree (never fatal).
clean_tree() {
  local branch="$1" dest="$2" path="$3"
  git --git-dir="$BARE" --work-tree="$dest" clean -fd -- "$path" 2>/dev/null || true
}

preserve() { cp "$1" "$2" 2>/dev/null || true; }   # preserve $1 to backup $2
restore()  { cp "$2" "$1" 2>/dev/null || true; }   # restore backup $2 to $1

own() { chown -R "${OWNER:-www-data:www-data}" "$1"; }

# --- cache / php-fpm ------------------------------------------------------------
flush_fastcgi() { [ -n "${1:-}" ] && rm -rf "$1"/* 2>/dev/null || true; }

flush_redis() {
  [ "${REDIS:-0}" = "1" ] || return 0
  wp cache flush --path="$1" --allow-root --quiet 2>/dev/null || true
}

# Reload/restart php-fpm to drop OPcache. FPM_ACTION=reload|restart, PHP_VER=8.x.
restart_fpm() {
  local action="${FPM_ACTION:-reload}" ver="${PHP_VER:-8.3}"
  systemctl "$action" "php${ver}-fpm" 2>/dev/null || systemctl restart "php${ver}-fpm"
}

# Post-deploy smoke test. The deploy hook reports success when the PUSH and BUILD
# succeeded — not when the site still works. A green banner over a broken site is
# the fleet's most expensive failure mode: an unconditional "deploy complete" left
# AVFTB production on an unpatched WordPress for 24 days.
#
# Asks WordPress where it lives rather than guessing from the docroot path, then
# hits that host on loopback so the check is not answered by a CDN edge and works
# before DNS exists. Never rolls anything back — the code is already live; this
# exists so the failure is LOUD, and so CI goes red instead of green.
smoke_test() {
  local dest="$1" env="$2"
  local wp="sudo -u www-data wp --path=wp"

  [ -f "$dest/wp/wp-load.php" ] || { log "smoke: core not present, skipped"; return 0; }
  ( cd "$dest" && $wp core is-installed >/dev/null 2>&1 ) || { log "smoke: WordPress not installed, skipped"; return 0; }

  local home host scheme port codenum
  home="$( cd "$dest" && $wp option get home 2>/dev/null )"
  [ -n "$home" ] || { log "smoke: could not resolve home_url, skipped"; return 0; }
  host="${home#*://}"; host="${host%%/*}"
  scheme=https; port=443
  [ -d "/etc/letsencrypt/live/${host}" ] || { scheme=http; port=80; }

  codenum="$(curl -sk --resolve "${host}:${port}:127.0.0.1" -o /dev/null -w '%{http_code}' "${scheme}://${host}/" || echo 000)"
  if [ "$codenum" = 200 ] || [ "$codenum" = 301 ] || [ "$codenum" = 302 ]; then
    log "smoke: ${host} -> ${codenum} OK"
    return 0
  fi

  # A password-gated site (GATED=1 in the site conf) answers anonymous visitors
  # with its gate as a 401 — that is the site working. Only for gated sites: on
  # any other site a 401 means something is wrong.
  if [ "${GATED:-0}" = 1 ] && [ "$codenum" = 401 ]; then
    log "smoke: ${host} -> 401 OK (gated)"
    return 0
  fi

  echo "============================================" >&2
  log "SMOKE TEST FAILED: ${host} returned ${codenum}" >&2
  log "The code IS deployed to ${env} (${dest}) — this is not a rollback." >&2
  log "The site is not serving. Check php-fpm, the theme build, and the error log." >&2
  echo "============================================" >&2
  return 1
}
