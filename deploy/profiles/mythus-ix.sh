#!/bin/bash
# Profile: mythus-ix — a WordPress site on the Mythus mu-plugin + IX parent theme +
# a child theme (Composer + npm build). Mirrors the hand-written post-receive hooks
# on View / Matchbook / Celeb Auto, parameterized by the site conf.
#
# Site conf must define: THEME (child theme dir), PHP_VER, FPM_ACTION (reload|restart),
# REDIS (0|1), and the maps DEPLOY_DIR[branch], ENV_NAME[branch], CACHE_DIR[branch].

profile_deploy() {
  local branch="$1" dest="$2" env="$3"
  local wp_path="$dest/wp"
  local child="$dest/wp-content/themes/${THEME:?THEME required for mythus-ix}"
  local ix="$dest/wp-content/themes/ix"
  local mythus="$dest/wp-content/mu-plugins/mythus"
  local envbak="/tmp/${THEME}-env-${env}.php"

  preserve "$dest/wp-config-env.php" "$envbak"      # env config is not in the repo
  checkout_tree "$branch" "$dest"
  clean_tree "$branch" "$dest" "wp-content/themes/${THEME}/src"
  restore "$dest/wp-config-env.php" "$envbak"
  cp /root/.composer-auth.json "$dest/auth.json" 2>/dev/null || true   # ACF Pro auth

  log "composer install (root + mythus + ix + child)…"
  ( cd "$dest";   COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction --no-scripts )
  [ -f "$mythus/composer.json" ] && ( cd "$mythus"; COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction )
  [ -f "$ix/composer.json" ]     && ( cd "$ix";     COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction )
  [ -f "$child/composer.json" ]  && ( cd "$child";  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction )

  log "npm build (ix + child)…"
  [ -f "$ix/package.json" ]    && ( cd "$ix";    npm install --no-audit --no-fund; npm run build )
  [ -f "$child/package.json" ] && ( cd "$child"; npm install --no-audit --no-fund; npm run build )

  own "$dest"
  # Clear caches AFTER code is in place: php-fpm (OPcache) first, then the nginx
  # FastCGI page cache + Redis object cache so they repopulate from fresh code.
  restart_fpm
  flush_fastcgi "$(conf_map CACHE_DIR "$branch")"
  flush_redis "$wp_path"
}
