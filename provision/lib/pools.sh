# deploy-kit — PHP-FPM pool helpers. Sourced by provision/fpm-pools.sh and the tests.
# render_pool and rewire_vhost_socket only print or rewrite files; ensure_user creates
# the account, and is shared with new-site.sh, which needs the users before the pools.

# render_pool <pool_name> <php_ver> <prod|staging> [max_children] [user]
#   prod:    pm=dynamic, max_children default 6 — sized for ~70 MB per worker.
#   staging: pm=ondemand, max 2, idle workers exit after 30s, so staging costs no
#            memory while nobody uses it and can never take production's workers.
# Both write a slow log: any request over 2s leaves a PHP stack trace.
# user: the Unix user (and group) PHP runs as — default www-data. Give each pool its own
# and the sites stop being able to read each other's secrets or write each other's
# files. The socket stays owned by www-data either way: that is nginx connecting.
render_pool() {
  local name="$1" ver="$2" kind="$3" max="${4:-}" user="${5:-www-data}"
  local sock="/run/php/php${ver}-fpm-${name}.sock"
  local slow="/var/log/php${ver}-fpm-${name}.slow.log"
  cat <<POOL
; deploy-kit — ${kind} pool [${name}]. Rendered by provision/fpm-pools.sh; re-run it
; rather than hand-editing. One pool per site per environment, so staging deploys,
; test runs and bots on one environment cannot take workers from another.
[${name}]
user = ${user}
group = ${user}
listen = ${sock}
listen.owner = www-data
listen.group = www-data

POOL
  if [ "$kind" = prod ]; then
    cat <<POOL
pm = dynamic
pm.max_children = ${max:-6}
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500
POOL
  else
    cat <<POOL
pm = ondemand
pm.max_children = ${max:-2}
pm.process_idle_timeout = 30s
pm.max_requests = 200
POOL
  fi
  cat <<POOL

; Any request over 2s writes a stack trace — check this first when a site is slow.
request_slowlog_timeout = 2s
slowlog = ${slow}
POOL
}

# rewire_vhost_socket <vhost_file> <php_ver> <pool_name>
#   Points every `fastcgi_pass unix:/run/php/php<ver>-fpm*.sock;` in the file at the
#   pool's socket. Rewrites in place; prints the number of lines changed.
rewire_vhost_socket() {
  local file="$1" ver="$2" name="$3"
  local want="unix:/run/php/php${ver}-fpm-${name}.sock"
  local n
  n="$(grep -cE "fastcgi_pass[[:space:]]+unix:/run/php/php${ver//./\\.}-fpm[^;]*\.sock;" "$file" || true)"
  sed -E -i "s#(fastcgi_pass[[:space:]]+)unix:/run/php/php${ver//./\\.}-fpm[^;]*\.sock;#\1${want};#g" "$file"
  echo "$n"
}

# A pool whose user does not exist fails php-fpm -t; create it as a system account that
# cannot log in and owns nothing yet.
ensure_user() {
  [ "$1" = www-data ] && return 0
  if ! id -u "$1" >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$1"
    echo ">> created system user $1"
  fi
  # A pool user must be able to read the mail relay config, or that site's web mail
  # fails silently (mail.sh MAIL_GROUP). Join it when the box has one; the reload that
  # follows gives the new workers the group.
  if getent group mailrelay >/dev/null && ! id -nG "$1" | tr ' ' '\n' | grep -qx mailrelay; then
    usermod -aG mailrelay "$1"; echo ">> added $1 to mailrelay"
  fi
}
