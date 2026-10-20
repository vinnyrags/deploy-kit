#!/bin/bash
# deploy-kit — give a site its own PHP-FPM pool per environment, with a slow log.
#
# The distro default is ONE pool, [www], shared by every vhost on the droplet. Staging,
# production, a demo and every bot all queue for the same workers, so a staging deploy,
# a test run or a scanner on one site makes another site's visitors wait. On a 1 GB
# droplet that shared pool (5 workers) filled four times in one day and produced
# 3–28 s page loads. One pool per site per environment ends that.
#
#   Usage:
#     fpm-pools.sh <slug> <php_ver> [--prod <vhost>] [--staging <vhost>] [--max N]
#                  [--user U] [--staging-user U]
#     fpm-pools.sh --retire-default <php_ver>   remove [www] once no vhost uses its socket
#     fpm-pools.sh --check                       list pools and which socket each vhost uses
#
#   <vhost> is the file name under /etc/nginx/sites-enabled/ (e.g. example.com).
#   --prod   → pool "<slug>",         pm=dynamic, max_children N (default 6)
#   --staging→ pool "<slug>-staging", pm=ondemand, max 2
#   A demo with no production goes in as --staging.
#   --user / --staging-user → the Unix user that pool runs as (default www-data). A
#   missing user is created as a no-login system user. This only changes who PHP runs
#   as: chown the site's writable paths and run lock_secrets for it as part of the same
#   change (and set POOL_USER in the site conf so deploys and wp-cron agree), or the
#   site cannot write uploads or read its own wp-config-env.php.
#
# Sizing: ~70 MB RSS per worker. Check `free -m` before raising --max; the sum of every
# pool's max_children × 70 MB must fit beside MariaDB, Redis and the page cache.
#
# Idempotent. Backs up pool.d and every vhost it edits to /root/fpm-bak/<stamp>/;
# validates php-fpm AND nginx before reloading either, and restores everything if
# either test fails.
set -euo pipefail

KIT="${KIT:-/opt/deploy-kit}"
# shellcheck disable=SC1091
source "$KIT/provision/lib/pools.sh"
log(){ echo ">> $*"; }

if [ "${1:-}" = "--check" ]; then
  echo "=== pools ==="
  grep -H '^\[' /etc/php/*/fpm/pool.d/*.conf 2>/dev/null | sed 's|^/etc/php/||; s|/fpm/pool.d/| |' || true
  echo "=== vhost sockets ==="
  for v in /etc/nginx/sites-enabled/*; do
    [ -e "$v" ] || continue
    grep -ohE 'fastcgi_pass[[:space:]]+unix:[^;]+' "$(readlink -f "$v")" 2>/dev/null \
      | sort -u | sed "s|^|  $(basename "$v")  |" || true
  done
  exit 0
fi

if [ "${1:-}" = "--retire-default" ]; then
  VER="${2:?php_ver}"
  DEF="/run/php/php${VER}-fpm.sock"
  users="$(grep -rlF "unix:${DEF};" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null || true)"
  if [ -n "$users" ]; then
    echo "REFUSING: still in use by:"; echo "$users" | sed 's/^/  /'; exit 1
  fi
  POOL="/etc/php/${VER}/fpm/pool.d/www.conf"
  [ -f "$POOL" ] || { log "no www.conf — nothing to retire"; exit 0; }
  mkdir -p /root/fpm-bak && cp -a "$POOL" "/root/fpm-bak/www.conf.$(date +%Y%m%d-%H%M%S)"
  rm "$POOL"
  "php-fpm${VER}" -t && systemctl reload "php${VER}-fpm"
  log "retired [www] (backup in /root/fpm-bak/)"
  exit 0
fi

SLUG="${1:?slug}"; VER="${2:?php_ver}"; shift 2
PROD=""; STG=""; MAX=""; PUSER="www-data"; SUSER="www-data"
while [ $# -gt 0 ]; do
  case "$1" in
    --prod)    PROD="${2:?vhost}"; shift ;;
    --staging) STG="${2:?vhost}"; shift ;;
    --max)     MAX="${2:?n}"; shift ;;
    --user)    PUSER="${2:?user}"; shift ;;
    --staging-user) SUSER="${2:?user}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$PROD$STG" ] || { echo "need --prod and/or --staging" >&2; exit 2; }

POOLD="/etc/php/${VER}/fpm/pool.d"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p /root/fpm-bak
BACKUP="$(mktemp -d "/root/fpm-bak/${SLUG}-${STAMP}-XXXX")"   # unique per run, see harden.sh
cp -a "$POOLD" "$BACKUP/pool.d"
: > "$BACKUP/manifest.txt"
log "backups -> $BACKUP"

restore() {
  log "restoring from $BACKUP"
  rm -rf "$POOLD" && cp -a "$BACKUP/pool.d" "$POOLD"
  while IFS=$'\t' read -r b path; do
    [ -n "$b" ] && cp "$BACKUP/$b" "$path"
  done < "$BACKUP/manifest.txt"
}

# A pool whose user does not exist fails php-fpm -t; create it as a system account that
# cannot log in and owns nothing yet.
ensure_user() {
  [ "$1" = www-data ] && return 0
  id -u "$1" >/dev/null 2>&1 && return 0
  useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$1"
  log "created system user $1"
}

apply() {  # apply <vhost> <pool> <kind> <user>
  local vhost="$1" pool="$2" kind="$3" user="$4" link real n
  link="/etc/nginx/sites-enabled/${vhost}"
  [ -e "$link" ] || { echo "no such vhost: $link" >&2; restore; exit 1; }
  # sites-enabled may hold real files that have drifted from sites-available — edit
  # the file nginx actually loads (see harden.sh).
  real="$(readlink -f "$link")"
  ensure_user "$user"
  render_pool "$pool" "$VER" "$kind" "$([ "$kind" = prod ] && echo "$MAX")" "$user" > "${POOLD}/${pool}.conf"
  cp "$real" "$BACKUP/${vhost}"; printf '%s\t%s\n' "$vhost" "$real" >> "$BACKUP/manifest.txt"
  n="$(rewire_vhost_socket "$real" "$VER" "$pool")"
  log "pool [${pool}] (${kind}, user ${user}) ← ${vhost} (${n} fastcgi_pass line(s))"
}

[ -n "$PROD" ] && apply "$PROD" "$SLUG" prod "$PUSER"
[ -n "$STG" ]  && apply "$STG" "${SLUG}-staging" staging "$SUSER"

# Pools first: nginx -t does not check that a socket exists, but a reload pointing at a
# socket php-fpm has not created yet would 502 until it does.
if ! "php-fpm${VER}" -t 2>&1 | tail -1; then restore; echo "php-fpm -t FAILED — reverted" >&2; exit 1; fi
systemctl reload "php${VER}-fpm"
for p in ${PROD:+$SLUG} ${STG:+${SLUG}-staging}; do
  for _ in 1 2 3 4 5; do [ -S "/run/php/php${VER}-fpm-${p}.sock" ] && break; sleep 1; done
  [ -S "/run/php/php${VER}-fpm-${p}.sock" ] || { restore; systemctl reload "php${VER}-fpm"; echo "socket for [${p}] never appeared — reverted" >&2; exit 1; }
done

if ! nginx -t 2>&1; then
  restore; systemctl reload "php${VER}-fpm"; echo "nginx -t FAILED — reverted" >&2; exit 1
fi
systemctl reload nginx

cat <<EOF

>> DONE. Verify from your laptop that each site still serves, then:
     fpm-pools.sh --check
   When no vhost uses the shared [www] socket any more:
     fpm-pools.sh --retire-default ${VER}
   Slow requests (>2s) now leave traces in /var/log/php${VER}-fpm-<pool>.slow.log
EOF
