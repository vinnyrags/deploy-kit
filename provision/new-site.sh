#!/bin/bash
# deploy-kit — provision ONE Mythus/IX WordPress site's infra on a base-provisioned
# droplet, on the vincentragosta.io standard from birth:
#   - a Unix user per environment and a PHP-FPM pool running as it (with slow log);
#   - LAYOUT=releases under /srv/<host>/: root-owned read-only releases, mutable state in
#     shared/, `current` switched atomically and rolled back on a failed smoke test;
#   - prod+staging DBs, wp-config-env.php in shared/ (640 root:<pool user>) with fresh
#     DB credentials and salts per environment;
#   - bare repo + deploy-kit hook + site conf, nginx vhosts + FastCGI cache blocks;
#   - WP-Cron from a system timer as the pool user (DISABLE_WP_CRON is set in the env file).
#
# Does NOT: deploy code (that's the first `git push`), issue TLS, `wp core install`, or
# set up backups (they need off-site credentials). It prints those steps. Refuses to
# touch anything that already exists.
#
#   Usage:  new-site.sh <slug> <prod_domain> [php_ver] [theme] [--user NAME] [--max N]
#     slug          short name → bare repo, conf, cache names, DBs (e.g. aviewfromthebridge)
#     prod_domain   e.g. viewfromthebridgeplay.com   (staging = staging.<domain>)
#     php_ver       default 8.4
#     theme         child theme dir (default = slug)
#     --user NAME   pool users NAME and NAME-stg (default: the slug, letters and digits)
#     --max N       production pool workers (default 6; ~70 MB each — check `free -m`)
#
#   MariaDB root: socket auth by default (a fresh provision-base.sh box). A box whose root
#   has a password needs MYSQL_DEFAULTS_FILE=<0600 file with a [client]
#   section: user=root, password=…>, so the password never reaches the command line.
#
# The kit stays at the ref /opt/deploy-kit is pinned to. Roll the pin deliberately.
set -euo pipefail
POS=(); USER_BASE=""; MAX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_BASE="${2:?name}"; shift ;;
    --max)  MAX="${2:?n}"; shift ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) POS+=("$1") ;;
  esac
  shift
done
SLUG="${POS[0]:?slug}"; DOMAIN="${POS[1]:?prod domain}"; PHP_VER="${POS[2]:-8.4}"; THEME="${POS[3]:-$SLUG}"
KIT="${DEPLOY_KIT_DIR:-/opt/deploy-kit}"
# shellcheck disable=SC1091
source "$KIT/deploy/lib/common.sh"
# shellcheck disable=SC1091
source "$KIT/provision/lib/pools.sh"
# shellcheck disable=SC1091
source "$KIT/provision/lib/migrate.sh"
# shellcheck disable=SC1091
source "$KIT/provision/lib/site.sh"

SUFFIX="$(printf '%s' "$SLUG" | tr -cd 'a-z0-9')"       # nginx map var suffix
ZONE="$(printf '%s' "$SUFFIX" | tr 'a-z' 'A-Z')"        # cache keys_zone
ZONE_DIR="fastcgi-${SUFFIX}"
STG_DOMAIN="staging.${DOMAIN}"
PROD_BASE="/srv/${DOMAIN}"
STG_BASE="/srv/${STG_DOMAIN}"
BARE="/var/repo/${SLUG}.git"
CONF="/etc/deploy-kit/${SLUG}.conf"
read -r PUSER SUSER <<<"$(site_pool_users "$SUFFIX" "$USER_BASE")"

# --- preflight: refuse before anything is created ----------------------------------------
MYSQL=(mysql); [ -n "${MYSQL_DEFAULTS_FILE:-}" ] && MYSQL=(mysql --defaults-extra-file="$MYSQL_DEFAULTS_FILE")
"${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1 || {
  echo "REFUSING: cannot reach MariaDB as root. Socket auth is the default; on a box whose root" >&2
  echo "           has a password, set MYSQL_DEFAULTS_FILE (see the header of this script)." >&2
  exit 1; }
nginx -t >/dev/null 2>&1 || { echo "REFUSING: nginx -t already fails — fix the box first" >&2; exit 1; }
for p in "$BARE" "$CONF" "$PROD_BASE" "$STG_BASE" "/etc/nginx/sites-available/${DOMAIN}" \
         "/etc/nginx/sites-available/${STG_DOMAIN}" "/var/cache/nginx/${ZONE_DIR}"; do
  [ -e "$p" ] && { echo "REFUSING: $p already exists" >&2; exit 1; }
done
grep -q "keys_zone=${ZONE}:" /etc/nginx/conf.d/wp-fastcgi-cache.conf 2>/dev/null \
  && { echo "REFUSING: cache zone ${ZONE} already defined" >&2; exit 1; }
log "deploy-kit $(git -C "$KIT" describe --tags --always 2>/dev/null) — pool users ${PUSER} / ${SUSER}"

# --- pool users (before anything is chowned to them) -----------------------------------
ensure_user "$PUSER"
ensure_user "$SUSER"

# --- databases (as root) --------------------------------------------------------------
prod_db="${SUFFIX}_prod"; stg_db="${SUFFIX}_stg"
prod_pw="$(openssl rand -hex 16)"; stg_pw="$(openssl rand -hex 16)"
log "creating DBs ${prod_db} / ${stg_db}"
"${MYSQL[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${prod_db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`${stg_db}\`  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${prod_db}'@'localhost' IDENTIFIED BY '${prod_pw}';
CREATE USER IF NOT EXISTS '${stg_db}'@'localhost'  IDENTIFIED BY '${stg_pw}';
GRANT ALL ON \`${prod_db}\`.* TO '${prod_db}'@'localhost';
GRANT ALL ON \`${stg_db}\`.*  TO '${stg_db}'@'localhost';
FLUSH PRIVILEGES;
SQL

# --- release bases + per-env wp-config-env.php in shared/ -------------------------------
for env in prod stg; do
  if [ "$env" = prod ]; then base="$PROD_BASE"; url="https://${DOMAIN}";     db="$prod_db"; pw="$prod_pw"; wpenv="production"; dbg="false"; user="$PUSER"
  else                       base="$STG_BASE";  url="https://${STG_DOMAIN}"; db="$stg_db";  pw="$stg_pw";  wpenv="staging";    dbg="true";  user="$SUSER"; fi
  log "release base $base (pool user $user)"
  site_init_base "$base" "$user"
  { sed -e "s#{{DB_NAME}}#${db}#g" -e "s#{{DB_USER}}#${db}#g" -e "s#{{DB_PASSWORD}}#${pw}#g" \
        -e "s#{{WP_HOME}}#${url}#g" -e "s#{{WP_ENV}}#${wpenv}#g" -e "s#{{WP_DEBUG}}#${dbg}#g" \
        "$KIT/templates/wp-config-env.php.template"
    site_salts; } > "$base/shared/wp-config-env.php"
  lock_secrets "$base/shared" "$user"
done

# --- bare repo + site conf + hook -------------------------------------------------------
log "bare repo $BARE"
git init -q --bare "$BARE"
site_conf "$THEME" "$PHP_VER" "$PROD_BASE" "$STG_BASE" "$ZONE_DIR" "$PUSER" "$SUSER" > "$CONF"
bash "$KIT/provision/setup-droplet.sh" "$SLUG" "$CONF"

# --- nginx: cache include block + two vhosts --------------------------------------------
log "nginx cache include + vhosts"
sed -e "s#{{SITE}}#${SUFFIX}#g" -e "s#{{ZONE}}#${ZONE}#g" -e "s#{{ZONE_DIR}}#${ZONE_DIR}#g" \
    "$KIT/nginx/wp-fastcgi-cache.conf.template" >> /etc/nginx/conf.d/wp-fastcgi-cache.conf
site_vhost "$KIT/nginx/vhost.conf.template" "${DOMAIN} www.${DOMAIN}" "$PROD_BASE" "$PHP_VER" "$SUFFIX" "$ZONE" \
  > "/etc/nginx/sites-available/${DOMAIN}"
site_vhost "$KIT/nginx/vhost.conf.template" "$STG_DOMAIN" "$STG_BASE" "$PHP_VER" "$SUFFIX" "${ZONE}_STAGING" \
  > "/etc/nginx/sites-available/${STG_DOMAIN}"
ln -sf "/etc/nginx/sites-available/${DOMAIN}"     "/etc/nginx/sites-enabled/${DOMAIN}"
ln -sf "/etc/nginx/sites-available/${STG_DOMAIN}" "/etc/nginx/sites-enabled/${STG_DOMAIN}"
mkdir -p "/var/cache/nginx/${ZONE_DIR}" "/var/cache/nginx/${ZONE_DIR}-staging"
# The vhost template includes scanner-block.conf; a droplet hardened before that snippet
# existed would fail `nginx -t` on a missing file. harden.sh normally installs it.
[ -f /etc/nginx/snippets/scanner-block.conf ] || cp "$KIT/nginx/scanner-block.snippet.conf" /etc/nginx/snippets/scanner-block.conf

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

# Own pool per environment, as its own user — the template ships pointing at the shared
# default socket. Runs after the cache-key check because fpm-pools.sh reloads nginx itself.
KIT="$KIT" bash "$KIT/provision/fpm-pools.sh" "$SLUG" "$PHP_VER" --prod "$DOMAIN" --staging "$STG_DOMAIN" \
  --user "$PUSER" --staging-user "$SUSER" ${MAX:+--max "$MAX"}
systemctl reload nginx

# WP-Cron from a timer. Starting it now is safe: until WordPress is installed each run
# exits 0 without doing anything, and the env file already sets DISABLE_WP_CRON.
DEPLOY_KIT_DIR="$KIT" bash "$KIT/provision/wp-cron.sh" --install "$CONF" main develop >/dev/null
log "wp-cron timers: deploy-kit-wpcron@${SLUG}:main, deploy-kit-wpcron@${SLUG}:develop"

# Provisioning is not done until the site is verified. This deliberately runs
# before the "READY" banner: a banner that prints regardless of outcome is how
# this fleet lost 24 days on an unpatched production site.
echo
"$KIT/provision/verify-site.sh" "$SLUG" "$DOMAIN" --env both || {
  echo
  echo ">> Infra is provisioned but VERIFY FAILED (see above)."
  echo "   Pre-deploy failures are expected: no release exists, WordPress is not installed"
  echo "   and TLS is not issued yet. Re-run after the steps below and expect a clean pass."
}

cat <<DONE

>> SITE INFRA READY: ${SLUG}  (prod ${DOMAIN} / staging ${STG_DOMAIN}, php ${PHP_VER})
   Releases: ${PROD_BASE}/current, ${STG_BASE}/current — pool users ${PUSER} / ${SUSER}
   DB credentials and salts: ${PROD_BASE}/shared/wp-config-env.php (+ staging).

   NEXT — docs/new-site-runbook.md has each in full:
   1. Mac:  deploy-kit/bin/onboard.sh <repo_dir> <gh_repo> <droplet_ip> ${SLUG} [ssh_target]
   2. TLS before DNS (DNS-01), then the proxied records, Full (strict), minimum TLS 1.2.
   3. First deploy: push develop, then main. Each lands as a release.
   4. wp core install — as the pool user, from the release:
        cd ${STG_BASE}/current && sudo -u ${SUSER} wp --path=wp core install …
   5. Backups:  $KIT/provision/backup.sh --install ${CONF}  (then --init, --run, --healthchecks)
   6. VERIFY — exit 0 or it is not provisioned:
        $KIT/provision/verify-site.sh ${SLUG} ${DOMAIN} --env both
        bash $KIT/provision/audit.sh
DONE
