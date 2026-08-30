#!/bin/bash
# deploy-kit — BASE droplet provisioning. Brings a fresh Ubuntu 24.04 droplet to the
# canonical ARTHOUSE spec, matching the View reference box:
#   nginx 1.24 + php-fpm + mariadb 10.11 + git + node(nvm) + composer + wp-cli,
#   the nginx cache dir + drop-default vhost + the wp-fastcgi-cache include,
#   /var/repo, /etc/deploy-kit, and deploy-kit itself at /opt/deploy-kit.
# Idempotent. Run once per droplet, as root.
#
#   Usage:  provision-base.sh [php_ver]        (default 8.4)
#
# NOT automated here (do once, manually, right after): `mysql_secure_installation`
# to set the MariaDB root password. new-site.sh assumes root can create DBs.
set -euo pipefail
PHP_VER="${1:-8.4}"
export DEBIAN_FRONTEND=noninteractive
log(){ echo ">> $*"; }

log "apt update + base packages"
apt-get update -y
apt-get install -y software-properties-common curl git unzip ca-certificates
add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true   # for php8.4 on 24.04
apt-get update -y

log "nginx + mariadb + php${PHP_VER} + certbot"
apt-get install -y nginx mariadb-server certbot python3-certbot-nginx \
  php${PHP_VER}-fpm php${PHP_VER}-cli php${PHP_VER}-mysql php${PHP_VER}-curl \
  php${PHP_VER}-gd php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-zip \
  php${PHP_VER}-imagick php${PHP_VER}-intl php${PHP_VER}-bcmath

log "composer"
command -v composer >/dev/null || {
  curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
}

log "wp-cli"
command -v wp >/dev/null || {
  curl -fsSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
}

log "node via nvm (for the child theme npm build)"
if [ ! -s /root/.nvm/nvm.sh ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
export NVM_DIR=/root/.nvm; . "$NVM_DIR/nvm.sh"; nvm install --lts >/dev/null 2>&1 || true

log "dirs + nginx base"
mkdir -p /var/cache/nginx /var/repo /etc/deploy-kit
printf 'server { listen 80 default_server; listen [::]:80 default_server; server_name _; return 444; }\n' \
  > /etc/nginx/sites-available/000-drop-default
ln -sf /etc/nginx/sites-available/000-drop-default /etc/nginx/sites-enabled/000-drop-default
rm -f /etc/nginx/sites-enabled/default
touch /etc/nginx/conf.d/wp-fastcgi-cache.conf   # new-site.sh appends per-site blocks

# Droplet-level fastcgi_cache_key. Required by every vhost that sets `fastcgi_cache`.
#
# Its absence is only a WARNING — `nginx -t` still prints "test is successful" — so a
# missing key does NOT fail provisioning. It fails in production instead: every cached
# response collides on one key and the whole site serves whichever page cached first,
# for every URL. That is what happened to vincentragosta.io on 2026-08-30.
#
# Guarded because a second copy in the same context is a duplicate-directive error:
# already-provisioned boxes carry it in nginx.conf's http block.
if ! grep -rq 'fastcgi_cache_key' /etc/nginx/ 2>/dev/null; then
  cat > /etc/nginx/conf.d/00-fastcgi-cache-key.conf <<'CACHEKEY'
# Droplet-level FastCGI cache key — installed by provision-base.sh.
# Without it every cached response collides on a single key. See
# docs/droplet-cache-convention.md.
fastcgi_cache_key "$scheme$request_method$host$request_uri";
CACHEKEY
  log "installed droplet-level fastcgi_cache_key"
else
  log "fastcgi_cache_key already present — left alone"
fi

log "deploy-kit @ /opt/deploy-kit (pinned ${DEPLOY_KIT_REF:-main})"
[ -d /opt/deploy-kit/.git ] || git clone -q https://github.com/vinnyrags/deploy-kit /opt/deploy-kit
git -C /opt/deploy-kit fetch -q --tags origin
git -C /opt/deploy-kit checkout -q "${DEPLOY_KIT_REF:-main}"

log "wordpress hardening (cloudflare real-ip, wp-login rate limit, xmlrpc block)"
# Single source of truth — harden.sh is also the path for already-provisioned boxes,
# and re-running it is how the Cloudflare ranges get refreshed.
bash /opt/deploy-kit/provision/harden.sh

# `nginx -t &&` is not sufficient on its own: nginx exits 0 on warnings, so a config
# that is silently broken at runtime still passes. Assert the specific warning is absent.
nginx -t || exit 1
if nginx -t 2>&1 | grep -q 'no "fastcgi_cache_key"'; then
  echo "FATAL: fastcgi_cache is enabled with no fastcgi_cache_key." >&2
  echo "       nginx -t PASSES in this state; the site would serve one page for all URLs." >&2
  exit 1
fi
systemctl reload nginx
log "BASE DONE (php ${PHP_VER}). NEXT: run 'mysql_secure_installation', then new-site.sh per site."
