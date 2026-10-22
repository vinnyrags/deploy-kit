# deploy-kit — host baseline checks. Sourced by provision/audit.sh and the tests.
#
# Each check prints one line per finding: STATUS<TAB>ID<TAB>message, STATUS one of
# PASS / WARN / FAIL. FAIL means the box is off the baseline in a way that matters;
# WARN means opt-in or advisory. File-based checks read under $AUDIT_ROOT (default /)
# so the tests can point them at fixtures; checks that need a live service say so.

AUDIT_ROOT="${AUDIT_ROOT:-}"
r() { printf '%s%s' "$AUDIT_ROOT" "$1"; }
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# Active (uncommented) value of a directive in a config file.
directive() {  # directive <file> <name>
  grep -E "^[[:space:]]*$2[[:space:]]" "$1" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -1 \
    | sed -E "s/^[[:space:]]*$2[[:space:]]+//; s/;.*//"
}

# --- nginx ------------------------------------------------------------------------
audit_nginx_tls() {
  local v; v="$(directive "$(r /etc/nginx/nginx.conf)" ssl_protocols)"
  if [ -z "$v" ]; then emit WARN nginx.tls "no http-level ssl_protocols (each vhost decides)"
  elif printf '%s' "$v" | grep -qE '(^|[[:space:]])TLSv1(\.1)?([[:space:]]|$)'; then
    emit FAIL nginx.tls "ssl_protocols still lists TLSv1/TLSv1.1: $v"
  else emit PASS nginx.tls "ssl_protocols $v"; fi
}

audit_nginx_tokens() {
  [ "$(directive "$(r /etc/nginx/nginx.conf)" server_tokens)" = off ] \
    && emit PASS nginx.tokens "server_tokens off" \
    || emit FAIL nginx.tokens "server_tokens not off (Server header shows the nginx version)"
}

audit_nginx_gzip() {
  [ -n "$(directive "$(r /etc/nginx/nginx.conf)" gzip_types)" ] \
    && emit PASS nginx.gzip "gzip_types set" \
    || emit WARN nginx.gzip "no gzip_types — origin compresses HTML only"
}

audit_nginx_logformat() {
  grep -qE 'upstream_cache_status' "$(r /etc/nginx/nginx.conf)" 2>/dev/null \
    && emit PASS nginx.log "access log records cache status" \
    || emit WARN nginx.log "access log has no cache status/timing (hit ratio not measurable)"
}

# A default_server on 443 that refuses the handshake, so a direct-IP or unknown-host
# request is never answered with some site's certificate.
audit_nginx_catchall() {
  local f found=""
  for f in "$(r /etc/nginx/sites-enabled)"/*; do
    [ -e "$f" ] || continue
    if grep -qE 'listen[^;]*443[^;]*default_server' "$f" && grep -qE 'ssl_reject_handshake[[:space:]]+on' "$f"; then
      found="$(basename "$f")"
    fi
  done
  [ -n "$found" ] && emit PASS nginx.catchall "default_server rejects unknown hosts ($found)" \
                  || emit FAIL nginx.catchall "no 443 default_server with ssl_reject_handshake — unknown hosts get a real site's certificate"
}

# sites-enabled entries must be links: a real file there drifts from sites-available.
audit_nginx_symlinks() {
  local f bad=""
  for f in "$(r /etc/nginx/sites-enabled)"/*; do
    [ -e "$f" ] || continue
    [ -L "$f" ] || bad="$bad $(basename "$f")"
  done
  [ -z "$bad" ] && emit PASS nginx.links "every sites-enabled entry is a symlink" \
                || emit FAIL nginx.links "real files in sites-enabled (edits to sites-available are ignored):$bad"
}

# --- OS ----------------------------------------------------------------------------
audit_os_autoreboot() {
  grep -rhsE '^[[:space:]]*Unattended-Upgrade::Automatic-Reboot[[:space:]]+"true"' "$(r /etc/apt/apt.conf.d)" >/dev/null \
    && emit PASS os.autoreboot "unattended-upgrades reboots when required" \
    || emit FAIL os.autoreboot "unattended-upgrades never reboots — kernel/libc fixes stay unapplied"
}

audit_os_reboot_pending() {
  local f; f="$(r /var/run/reboot-required)"
  if [ ! -e "$f" ]; then emit PASS os.reboot "no reboot pending"; return; fi
  local days=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
  [ "$days" -le 2 ] && emit WARN os.reboot "reboot pending for ${days}d" \
                    || emit FAIL os.reboot "reboot pending for ${days}d — patches installed but not running"
}

audit_os_journald() {
  grep -rhsE '^[[:space:]]*SystemMaxUse=' "$(r /etc/systemd/journald.conf)" "$(r /etc/systemd/journald.conf.d)" >/dev/null \
    && emit PASS os.journald "journal size capped" \
    || emit WARN os.journald "journal size uncapped"
}

# Live: reads swapon. A box without swap OOM-kills PHP or MariaDB on a composer run.
audit_os_swap() {
  [ -n "$(swapon --show --noheadings 2>/dev/null)" ] && emit PASS os.swap "swap on" \
    || emit FAIL os.swap "no swap — a memory spike kills PHP or MariaDB (baseline.sh --swap)"
}

# --- PHP-FPM ------------------------------------------------------------------------
audit_php_pool_users() {
  local f u n www=""
  for f in "$(r /etc/php)"/*/fpm/pool.d/*.conf; do
    [ -e "$f" ] || continue
    u="$(sed -nE 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | tail -1)"
    n="$(basename "$f" .conf)"
    [ "$u" = www-data ] && www="$www $n"
  done
  [ -z "$www" ] && emit PASS php.users "no PHP pool runs as www-data" \
                || emit WARN php.users "pools still running as www-data (shared identity, opt-in to fix):$www"
}

# Every site's env file: 640, owned by root, group = that branch's pool user.
# Args: lines of "<env file path> <expected group>".
audit_php_secrets() {
  local path group found=0
  while read -r path group; do
    [ -n "$path" ] || continue
    found=1
    if [ ! -f "$(r "$path")" ]; then emit FAIL php.secrets "missing: $path"; continue; fi
    local got; got="$(stat -c '%U:%G %a' "$(r "$path")")"
    [ "$got" = "root:${group} 640" ] && emit PASS php.secrets "$path ($got)" \
                                     || emit FAIL php.secrets "$path is $got, want root:${group} 640"
  done
  [ "$found" = 1 ] || emit WARN php.secrets "no site confs found to check"
}

# --- per site -------------------------------------------------------------------------
# What every WordPress site on the box should have, from its conf rather than from what
# happens to be installed: a deploy-kit-backup timer that does not exist cannot fail.
# stdin: "<site> <branch> <profile> <layout>" per deployed branch (site_branches in
# audit.sh). $1: the enabled deploy-kit timer names, one per line.
#   site.backup  a site with a production branch (main) and no enabled backup timer: FAIL
#   site.cron    a branch with no WP-Cron timer: WARN (traffic-triggered cron behind a cache)
#   site.layout  a branch deployed in place: WARN (migrate-to-releases.sh)
# Only mythus-ix sites: a nextjs app has no database or WP-Cron, and classic deploys a
# theme into someone else's docroot.
audit_sites() {
  local timers="$1" site branch profile layout seen=" "
  while read -r site branch profile layout; do
    [ -n "$site" ] && [ "$profile" = mythus-ix ] || continue
    if [ "$branch" = main ] && [[ "$seen" != *" $site "* ]]; then
      seen="$seen$site "
      grep -qx "deploy-kit-backup@${site}.timer" <<<"$timers" \
        && emit PASS site.backup "$site: nightly off-site backup timer" \
        || emit FAIL site.backup "$site: production has no backup timer (backup.sh --install)"
    fi
    grep -qx "deploy-kit-wpcron@${site}:${branch}.timer" <<<"$timers" \
      && emit PASS site.cron "$site [$branch]: WP-Cron from a system timer" \
      || emit WARN site.cron "$site [$branch]: WP-Cron rides on traffic (wp-cron.sh --install)"
    [ "$layout" = releases ] \
      && emit PASS site.layout "$site [$branch]: atomic read-only releases" \
      || emit WARN site.layout "$site [$branch]: deployed in place (migrate-to-releases.sh)"
  done
  return 0
}

# --- mail ---------------------------------------------------------------------------
audit_mail_conf() {
  local f; f="$(r /etc/msmtprc)"
  [ -f "$f" ] || { emit WARN mail.conf "no /etc/msmtprc (no relay on this box)"; return; }
  local m; m="$(stat -c '%a' "$f")"
  case "$m" in
    640|600) emit PASS mail.conf "msmtprc mode $m ($(stat -c '%U:%G' "$f"))" ;;
    *)       emit FAIL mail.conf "msmtprc mode $m — relay credential readable by others" ;;
  esac
}

# --- ssh ----------------------------------------------------------------------------
# A human admin: a sudo-group user with a non-empty authorized_keys and a sudoers rule
# (provision/ssh-admin.sh). Without one, humans can only log in as root.
audit_ssh_admin() {
  local members u home found=""
  members="$(awk -F: '$1=="sudo"{print $4}' "$(r /etc/group)" 2>/dev/null | tr ',' ' ')"
  for u in $members; do
    home="$(awk -F: -v u="$u" '$1==u{print $6}' "$(r /etc/passwd)")"
    [ -s "$(r "$home/.ssh/authorized_keys")" ] && grep -qs "^$u " "$(r /etc/sudoers.d)"/* && found="$found $u"
  done
  [ -n "$found" ] && emit PASS sec.admin "sudo user with a key:$found" \
    || emit WARN sec.admin "no sudo user with an SSH key — humans log in as root (ssh-admin.sh --user)"
}
