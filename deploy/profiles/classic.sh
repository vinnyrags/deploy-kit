#!/bin/bash
# Profile: classic — a hand-built classic WordPress theme with NO build step (e.g.
# Shucked). The bare repo IS the theme, so DEPLOY_DIR[branch] points at the theme
# directory on the box; deploy is just a checkout. Server-resident media
# (gitignored) is left untouched.
#
# Site conf: DEPLOY_DIR[branch] = theme dir; optional CACHE_DIR/REDIS/PHP_VER +
# FPM_RELOAD=1 if the site is cached (Shucked currently is not).

profile_deploy() {
  local branch="$1" dest="$2" env="$3"
  checkout_tree "$branch" "$dest"
  own "$dest"
  log "checked out theme (server media left intact)"

  # Uncached + opcache.validate_timestamps=On needs nothing more. If the site later
  # gains a FastCGI cache / turns validate_timestamps off, set these in the conf.
  [ "${FPM_RELOAD:-0}" = "1" ] && restart_fpm || true
  flush_fastcgi "$(conf_map CACHE_DIR "$branch")"
  flush_redis "$dest"
}
