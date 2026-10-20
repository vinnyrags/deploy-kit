#!/bin/bash
# deploy-kit — shared helpers, sourced by deploy.sh and the profiles.
# Requires bash 4.3+ (namerefs). Ubuntu 24.04 ships bash 5.

log() { echo ">> $*"; }

# conf_map ARRAY_NAME KEY  ->  value of an associative array defined in the site conf.
# e.g. conf_map DEPLOY_DIR main
#
# An array the conf never declares reads as empty. Without the guard, set -u aborts
# on the nameref and takes the whole caller with it, even from inside `$(… || true)`:
# when LAYOUT arrived (7964eda) every conf without one failed its next deploy
# (heywilma-connect, 2026-10-16), before the profile had printed anything.
conf_map() {
  declare -p "$1" >/dev/null 2>&1 || return 0
  local -n _m="$1"
  printf '%s' "${_m[$2]:-}"
}

# One index per deployed branch. The bare repo's own index is shared by every work
# tree checked out from it, so with staging (develop) and production (main) on one
# bare repo, whichever deploys second inherits the first's record of what is already
# in place: a file deleted from the repo is removed from the first environment and
# silently left behind in the second, forever. That is how a retired bot's database,
# old one-off scripts and since-deleted docs survived in a production docroot
# (found 2026-10-15). A per-branch index gives each work tree its own record, so a
# deletion reaches every environment. The first deploy after this change starts from
# an empty index: it writes every tracked file but cannot know what was left behind
# before it — clear pre-existing leftovers once, by hand.
branch_index() { printf '%s/index.%s' "$BARE" "$(printf '%s' "$1" | tr '/' '_')"; }

# Check out a branch from the bare repo ($BARE) into a work tree, creating it.
checkout_tree() {
  local branch="$1" dest="$2"
  mkdir -p "$dest"
  GIT_INDEX_FILE="$(branch_index "$branch")" git --git-dir="$BARE" --work-tree="$dest" checkout -f "$branch"
}

# git clean, scoped, from the bare repo into a work tree (never fatal). Must use the
# same per-branch index as checkout_tree, or it would judge this work tree against
# another environment's record.
clean_tree() {
  local branch="$1" dest="$2" path="$3"
  GIT_INDEX_FILE="$(branch_index "$branch")" git --git-dir="$BARE" --work-tree="$dest" clean -fd -- "$path" 2>/dev/null || true
}

preserve() { cp "$1" "$2" 2>/dev/null || true; }   # preserve $1 to backup $2
restore()  { cp "$2" "$1" 2>/dev/null || true; }   # restore backup $2 to $1

own() { chown -R "${OWNER:-www-data:www-data}" "$1"; }

# The Unix user PHP runs as for a branch: POOL_USER[branch] in the site conf, else
# www-data. With one user per pool, the sites on a droplet cannot read each other's
# secrets or write each other's files — separate pools alone only separate workers.
# Everything that runs PHP or WordPress on a site's behalf (secrets group, wp-cron,
# the smoke test) asks this, so a conf without the map behaves exactly as before.
pool_user() {
  local u
  u="$(conf_map POOL_USER "$1")"
  printf '%s' "${u:-www-data}"
}

# Secret-bearing files in a docroot: readable by PHP (the pool's group), writable by
# nobody but root, invisible to other accounts. Runs AFTER own(), whose recursive
# chown would otherwise hand them back to the site user — a PHP RCE could then rewrite
# the DB credentials or salts rather than merely read them.
lock_secrets() {
  local f group="${2:-www-data}"
  for f in "$1/wp-config-env.php" "$1/auth.json"; do
    [ -f "$f" ] && chown "root:${group}" "$f" && chmod 640 "$f"
  done
  return 0
}

# --- cache / php-fpm ------------------------------------------------------------
flush_fastcgi() { [ -n "${1:-}" ] && rm -rf "$1"/* 2>/dev/null || true; }

flush_redis() {
  [ "${REDIS:-0}" = "1" ] || return 0
  wp cache flush --path="$1" --allow-root --quiet 2>/dev/null || true
}

# Rewrite rules live in the database, not the code: a deploy that changes a post
# type's or taxonomy's rewrite slug leaves the old rules in place, and the new URLs
# 404 with no error anywhere. Regenerating them is cheap, so do it every deploy.
# Soft flush — rules only; nginx has no .htaccess to write.
flush_rewrites() {
  wp rewrite flush --path="$1" --allow-root --quiet 2>/dev/null || true
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
#
# Runs WordPress as the site's pool user ($3, default www-data). It must be the user
# that can read wp-config-env.php: as anyone else, `core is-installed` fails, which
# lands in the "not installed, skipped" branch below and passes without testing.
smoke_test() {
  local dest="$1" env="$2" user="${3:-www-data}"
  local wp="sudo -u ${user} wp --path=wp"

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
