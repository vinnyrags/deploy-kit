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
