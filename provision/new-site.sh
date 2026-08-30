#!/bin/bash
# deploy-kit — provision ONE Mythus/IX WordPress site's infra on a base-provisioned
# droplet: prod+staging DBs, web roots, bare repo + deploy-kit hook + site.conf,
# nginx vhosts + FastCGI cache blocks, and per-env wp-config-env.php.
#
# Does NOT: deploy code (that's the first `git push`), run certbot (do after DNS),
# or `wp core install` (after the first deploy). Refuses to clobber an existing site.
#
#   Usage:  new-site.sh <slug> <prod_domain> [php_ver] [theme]
#     slug          short name → bare repo, cache names, DBs (e.g. aviewfromthebridge)
#     prod_domain   e.g. viewfromthebridgeplay.com   (staging = staging.<domain>)
#     php_ver       default 8.4
#     theme         child theme dir (default = slug)
set -euo pipefail
SLUG="${1:?slug}"; DOMAIN="${2:?prod domain}"; PHP_VER="${3:-8.4}"; THEME="${4:-$1}"
KIT="${DEPLOY_KIT_DIR:-/opt/deploy-kit}"

SUFFIX="$(printf '%s' "$SLUG" | tr -cd 'a-z0-9')"       # nginx map var suffix
ZONE="$(printf '%s' "$SUFFIX" | tr 'a-z' 'A-Z')"        # cache keys_zone
ZONE_DIR="fastcgi-${SUFFIX}"
STG_DOMAIN="staging.${DOMAIN}"
PROD_ROOT="/var/www/${DOMAIN}/public"
STG_ROOT="/var/www/${STG_DOMAIN}/public"
BARE="/var/repo/${SLUG}.git"
CONF="/etc/deploy-kit/${SLUG}.conf"

[ -e "$BARE" ] && { echo "REFUSING: $BARE already exists"; exit 1; }
log(){ echo ">> $*"; }
render(){ sed -e "s#{{SITE}}#${SUFFIX}#g" -e "s#{{ZONE}}#${ZONE}#g" -e "s#{{ZONE_DIR}}#${ZONE_DIR}#g" \
             -e "s#{{PHP_VER}}#${PHP_VER}#g" "$@"; }

# --- databases (root via socket auth) --------------------------------------------
prod_db="${SUFFIX}_prod"; stg_db="${SUFFIX}_stg"
prod_pw="$(openssl rand -hex 16)"; stg_pw="$(openssl rand -hex 16)"
log "creating DBs ${prod_db} / ${stg_db}"
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${prod_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`${stg_db}\`  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${prod_db}'@'localhost' IDENTIFIED BY '${prod_pw}';
CREATE USER IF NOT EXISTS '${stg_db}'@'localhost'  IDENTIFIED BY '${stg_pw}';
GRANT ALL ON \`${prod_db}\`.* TO '${prod_db}'@'localhost';
GRANT ALL ON \`${stg_db}\`.*  TO '${stg_db}'@'localhost';
FLUSH PRIVILEGES;
SQL

# --- web roots + per-env wp-config-env.php ---------------------------------------
for env in prod stg; do
  if [ "$env" = prod ]; then root="$PROD_ROOT"; url="https://${DOMAIN}";     db="$prod_db"; pw="$prod_pw"; wpenv="production"; dbg="false"; else
                              root="$STG_ROOT";  url="https://${STG_DOMAIN}"; db="$stg_db";  pw="$stg_pw"; wpenv="staging";    dbg="true"; fi
  log "web root $root"
  mkdir -p "$root"
  sed -e "s#{{DB_NAME}}#${db}#g" -e "s#{{DB_USER}}#${db}#g" -e "s#{{DB_PASSWORD}}#${pw}#g" \
      -e "s#{{WP_HOME}}#${url}#g" -e "s#{{WP_ENV}}#${wpenv}#g" -e "s#{{WP_DEBUG}}#${dbg}#g" \
      "$KIT/templates/wp-config-env.php.template" > "$root/wp-config-env.php"
  chown -R www-data:www-data "/var/www/$(echo "$root" | cut -d/ -f4)"
done

# --- bare repo + deploy-kit site.conf + hook -------------------------------------
log "bare repo $BARE"
git init -q --bare "$BARE"
cat > "$CONF" <<CONF
PROFILE=mythus-ix
THEME=${THEME}
PHP_VER=${PHP_VER}
FPM_ACTION=reload
REDIS=0
declare -A DEPLOY_DIR=( [main]=${PROD_ROOT} [develop]=${STG_ROOT} )
declare -A ENV_NAME=( [main]=production [develop]=staging )
declare -A CACHE_DIR=( [main]=/var/cache/nginx/${ZONE_DIR} [develop]=/var/cache/nginx/${ZONE_DIR}-staging )
CONF
bash "$KIT/provision/setup-droplet.sh" "$SLUG" "$CONF" "${DEPLOY_KIT_REF:-main}"

# --- nginx: cache include block + two vhosts -------------------------------------
log "nginx cache include + vhosts"
render "$KIT/nginx/wp-fastcgi-cache.conf.template" >> /etc/nginx/conf.d/wp-fastcgi-cache.conf
render -e "s#{{SERVER_NAMES}}#${DOMAIN} www.${DOMAIN}#g" -e "s#{{WEBROOT}}#${PROD_ROOT}#g" \
       -e "s#{{CACHE_ZONE}}#${ZONE}#g" "$KIT/nginx/vhost.conf.template" > "/etc/nginx/sites-available/${DOMAIN}"
render -e "s#{{SERVER_NAMES}}#${STG_DOMAIN}#g" -e "s#{{WEBROOT}}#${STG_ROOT}#g" \
       -e "s#{{CACHE_ZONE}}#${ZONE}_STAGING#g" "$KIT/nginx/vhost.conf.template" > "/etc/nginx/sites-available/${STG_DOMAIN}"
ln -sf "/etc/nginx/sites-available/${DOMAIN}"     "/etc/nginx/sites-enabled/${DOMAIN}"
ln -sf "/etc/nginx/sites-available/${STG_DOMAIN}" "/etc/nginx/sites-enabled/${STG_DOMAIN}"
mkdir -p "/var/cache/nginx/${ZONE_DIR}" "/var/cache/nginx/${ZONE_DIR}-staging"

# This script is what turns caching ON for a site, so it is the last point at which a
# missing droplet-level fastcgi_cache_key can be caught before it reaches production.
# `nginx -t` alone will NOT catch it — nginx warns and exits 0. Without the key every
# cached response collides on one key and the site serves one page for every URL.
nginx -t || exit 1
if nginx -t 2>&1 | grep -q 'no "fastcgi_cache_key"'; then
  echo "FATAL: this vhost enables fastcgi_cache but the droplet has no fastcgi_cache_key." >&2
  echo "       Run provision-base.sh, or add it to nginx.conf's http block, then re-run." >&2
  echo "       See docs/droplet-cache-convention.md." >&2
  exit 1
fi
systemctl reload nginx

cat <<DONE

>> SITE INFRA READY: ${SLUG}  (prod ${DOMAIN} / staging ${STG_DOMAIN}, php ${PHP_VER})
   DB creds are in ${PROD_ROOT}/wp-config-env.php (+ staging). Save them if needed.

   NEXT (adjacent steps):
   1. From your Mac:  deploy-kit/bin/onboard.sh <repo_dir> <ghrepo> <droplet_ip> ${SLUG}
      (sets the deploy key + GitHub secrets + caller workflow)
   2. Point DNS (Cloudflare) for ${DOMAIN}, www, ${STG_DOMAIN} at this droplet.
   3. TLS:  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN}   and   certbot --nginx -d ${STG_DOMAIN}
      (or DNS-01 pre-issue for a no-gap cutover — see the Shucked runbook).
   4. First deploy: push develop/main → the code lands + builds.
   5. wp core install / import the DB.
DONE
