# deploy-kit — host baseline helpers. Sourced by provision/baseline.sh and the tests.
# Pure: they print, or rewrite the one file they are given. No services touched.
#
# The baseline these render is what provision/audit.sh checks for, so a box brought up
# with baseline.sh passes the audit, and drift on a running box shows up as an audit FAIL.

# nginx_set <nginx.conf> <directive> <value>
#   Set an http-level directive in nginx.conf: replace its first ACTIVE occurrence (a
#   commented-out line is ignored and left alone), or insert it before the conf.d
#   include if it is absent. In place, because directives such as ssl_protocols cannot
#   appear twice in one context — a conf.d drop-in would collide with the distro's line.
#   Prints "set", "added" or "unchanged".
nginx_set() {
  local file="$1" name="$2" value="$3" want cur
  want="${name} ${value};"
  cur="$(grep -E "^[[:space:]]*${name}[[:space:]]" "$file" | head -1 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+#.*$//')"
  if [ "$cur" = "$want" ]; then echo unchanged; return 0; fi
  if [ -n "$cur" ]; then
    awk -v n="$name" -v w="$want" '
      !done && $0 ~ "^[[:space:]]*" n "[[:space:]]" { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) w; done=1; next }
      { print }' "$file" > "$file.dk-tmp" && mv "$file.dk-tmp" "$file"
    echo set
  else
    grep -qE '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' "$file" \
      || { echo "no conf.d include in $file — cannot place $name" >&2; return 1; }
    awk -v w="$want" '
      !done && /^[[:space:]]*include[[:space:]]+\/etc\/nginx\/conf\.d\/\*\.conf;/ { match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) w; done=1 }
      { print }' "$file" > "$file.dk-tmp" && mv "$file.dk-tmp" "$file"
    echo added
  fi
}

# The default_server for every host this box does not serve: no certificate is
# presented on 443 and port 80 closes the connection, so a direct-IP scan cannot learn
# a hostname from a real site's certificate. Named vhosts and certbot HTTP-01 match by
# server_name and are unaffected.
render_catchall() {
  cat <<'CONF'
# deploy-kit baseline — catch-all for any request whose Host/SNI matches no vhost
# (direct-IP scans, stale DNS, mis-pointed domains). Without it nginx falls back to the
# first vhost loaded and presents that site's certificate, naming it to every scanner.
# 443 refuses the handshake; 80 closes the connection. Named vhosts are unaffected.
# Undo: rm /etc/nginx/sites-enabled/00-catchall && nginx -t && systemctl reload nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_reject_handshake on;
    access_log /var/log/nginx/catchall.access.log;
    return 444;
}
CONF
}

# render_unattended <reboot_time> [extra_origin]
#   Reboot when an installed update requires it, at a quiet hour; drop old kernels.
#   extra_origin: e.g. "o=LP-PPA-ondrej-php,a=noble" so PHP patches arrive too.
render_unattended() {
  local at="$1" origin="${2:-}"
  echo '// deploy-kit baseline: local overrides, kept out of the distro conffile so package upgrades never prompt.'
  [ -n "$origin" ] && printf 'Unattended-Upgrade::Origins-Pattern { "%s"; };\n' "$origin"
  cat <<CONF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "${at}";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
CONF
}

render_journald() {  # render_journald <max>
  printf '# deploy-kit baseline: cap the journal so it cannot fill the disk.\n[Journal]\nSystemMaxUse=%s\n' "$1"
}

render_php_local() {  # render_php_local <memory_limit> <upload_max>
  cat <<INI
; deploy-kit baseline: local PHP-FPM overrides. php.ini stays the distro file.
; Size memory_limit from the heaviest real request, not the distro guess; the sum over
; every pool's max_children must fit in RAM. Uploads match nginx client_max_body_size.
memory_limit = $1
upload_max_filesize = $2
post_max_size = $2
INI
}

# The nginx.conf directives the baseline owns, as "name<TAB>value" lines.
baseline_nginx_directives() {
  printf '%s\t%s\n' \
    ssl_protocols 'TLSv1.2 TLSv1.3' \
    ssl_prefer_server_ciphers off \
    server_tokens off \
    gzip_vary on \
    gzip_proxied any \
    gzip_comp_level 5 \
    gzip_min_length 256 \
    gzip_types 'text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml application/ld+json'
}

# nginx_ensure_log_format <nginx.conf>
#   Define `log_format timed` (combined + host, page-cache status, total and upstream
#   time, appended at the END so tools reading the combined columns keep working) before
#   the first active access_log line — nginx rejects a format used before it is defined.
#   Left alone if any `log_format timed` already exists. Prints "added" or "present".
nginx_ensure_log_format() {
  local file="$1"
  if grep -qE '^[[:space:]]*log_format[[:space:]]+timed[[:space:]]' "$file"; then echo present; return 0; fi
  grep -qE '^[[:space:]]*access_log[[:space:]]' "$file" || { echo "no access_log in $file" >&2; return 1; }
  awk '
    !done && /^[[:space:]]*access_log[[:space:]]/ {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      print ind "log_format timed '"'"'$remote_addr - $remote_user [$time_local] \"$request\" $status $body_bytes_sent \"$http_referer\" \"$http_user_agent\" host=$host cache=$upstream_cache_status rt=$request_time urt=$upstream_response_time'"'"';"
      done = 1
    }
    { print }' "$file" > "$file.dk-tmp" && mv "$file.dk-tmp" "$file"
  echo added
}
