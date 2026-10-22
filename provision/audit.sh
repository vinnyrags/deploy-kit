#!/bin/bash
# deploy-kit — read-only host baseline audit. Run ON a droplet as root:
#
#     audit.sh              # every check, one line each; exit 1 on any FAIL
#     audit.sh --fail-only  # only WARN/FAIL lines
#
# It answers "is this box still on the baseline the kit installs?" — the drift check.
# It changes nothing, installs nothing and sends nothing. It is not monitoring: no timer,
# no alerts (monitoring is parked by decision).
#
# Site-aware checks read /etc/deploy-kit/*.conf: each WordPress site's env file must be
# 640 root:<its pool user> (POOL_USER, default www-data).
set -uo pipefail

KIT="${KIT:-/opt/deploy-kit}"
# shellcheck disable=SC1091
source "$KIT/provision/lib/audit.sh"
# shellcheck disable=SC1091
source "$KIT/deploy/lib/common.sh"
FAIL_ONLY=0; [ "${1:-}" = --fail-only ] && FAIL_ONLY=1

# --- live checks (need the real services) -------------------------------------------
audit_nginx_test() {
  local out; out="$(nginx -t 2>&1)"
  if ! printf '%s' "$out" | grep -q 'test is successful'; then emit FAIL nginx.test "nginx -t fails"
  elif printf '%s' "$out" | grep -q '\[warn\]'; then
    emit FAIL nginx.test "nginx -t passes WITH warnings (a missing fastcgi_cache_key is only a warning): $(printf '%s' "$out" | grep -m1 '\[warn\]')"
  else emit PASS nginx.test "nginx -t clean, no warnings"; fi
}

audit_os_failed_units() {
  local f; f="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  [ -z "$f" ] && emit PASS os.units "no failed systemd units" || emit FAIL os.units "failed units: $f"
}

audit_os_php_cli() {
  local cli fpm
  cli="$(readlink -f /etc/alternatives/php 2>/dev/null | sed 's#.*/php##')"
  fpm="$(ls /etc/php/*/fpm/pool.d 2>/dev/null -d | sed -E 's#/etc/php/([^/]+)/.*#\1#' | sort -V | tail -1)"
  if [ -n "$fpm" ] && [ "$cli" != "$fpm" ]; then emit FAIL os.phpcli "php CLI is $cli but FPM serves $fpm — wp-cli runs a different PHP"
  else emit PASS os.phpcli "php CLI $cli matches FPM"; fi
}

audit_security() {
  systemctl is-active -q ufw 2>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active' \
    && emit PASS sec.ufw "ufw active" || emit FAIL sec.ufw "ufw not active"
  local jails; jails="$(fail2ban-client status 2>/dev/null | sed -nE 's/.*Jail list:[[:space:]]*//p')"
  [ -n "$jails" ] && emit PASS sec.fail2ban "fail2ban jails: $jails" || emit FAIL sec.fail2ban "fail2ban not running or no jails"
  [ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')" = no ] \
    && emit PASS sec.sshpw "SSH password login off" || emit FAIL sec.sshpw "SSH password login allowed"
  case "$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}')" in
    no|forced-commands-only) emit PASS sec.sshroot "root SSH restricted" ;;
    *) emit WARN sec.sshroot "root can log in interactively (keys only) — humans should use a sudo user" ;;
  esac
  [ "$(sshd -T 2>/dev/null | awk '/^x11forwarding /{print $2}')" = no ] \
    && emit PASS sec.x11 "SSH X11 forwarding off" || emit WARN sec.x11 "SSH X11 forwarding on (ssh-admin.sh --no-x11)"
}

# A Node.js app running as root turns any RCE in it into root on the box. Match the process
# NAME (comm), never the command line: a pattern in args would match this check's own awk.
audit_node_root() {
  local n; n="$(ps -eo user=,comm= | awk '$1=="root" && ($2=="node" || $2 ~ /^next-server/)' | wc -l)"
  [ "$n" -eq 0 ] && emit PASS os.noderoot "no Node.js process runs as root" \
    || emit WARN os.noderoot "$n Node.js process(es) run as root — move the app to its own user (nextjs-service.sh)"
}

audit_backups() {
  local t svc res any=0
  # Template instances only show up in list-timers (list-unit-files lists the template).
  for t in $(systemctl list-timers --all --no-legend 'deploy-kit-backup@*' 2>/dev/null \
             | grep -oE 'deploy-kit-backup@[^ ]+\.timer' | sort -u); do
    any=1; svc="${t%.timer}.service"
    systemctl is-enabled -q "$t" 2>/dev/null && emit PASS backup.timer "$t enabled" || emit FAIL backup.timer "$t not enabled"
    res="$(systemctl show "$svc" -p Result --value 2>/dev/null)"
    [ "$res" = success ] && emit PASS backup.last "$svc last run: success" || emit FAIL backup.last "$svc last run: ${res:-never}"
    systemctl show "$svc" -p DropInPaths --value 2>/dev/null | grep -qi healthcheck \
      && emit PASS backup.alert "$svc pings a dead-man's switch" \
      || emit WARN backup.alert "$svc has no dead-man's switch — a backup that stops running alerts nobody"
  done
  [ "$any" = 1 ] || emit WARN backup.timer "no deploy-kit backup timers on this box"
}

# Every pool user must be able to read the relay config, or that site's web mail fails
# silently (RUNBOOK trap 2); nginx (www-data) should not, once no PHP runs as it.
audit_mail_readers() {
  [ -f /etc/msmtprc ] || return 0
  local f u
  for f in /etc/php/*/fpm/pool.d/*.conf; do
    [ -e "$f" ] || continue
    u="$(sed -nE 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | tail -1)"
    sudo -u "$u" test -r /etc/msmtprc 2>/dev/null \
      && emit PASS mail.read "pool $(basename "$f" .conf) ($u) can read the relay config" \
      || emit FAIL mail.read "pool $(basename "$f" .conf) ($u) CANNOT read /etc/msmtprc — its web mail fails silently"
  done
}

# "<env file> <pool user>" for every WordPress branch in every site conf.
site_secrets() {
  local conf
  for conf in /etc/deploy-kit/*.conf; do
    [ -r "$conf" ] || continue
    (
      # shellcheck disable=SC1090
      . "$conf" >/dev/null 2>&1
      [ "${PROFILE:-}" = mythus-ix ] || exit 0
      for b in "${!DEPLOY_DIR[@]}"; do
        d="${DEPLOY_DIR[$b]}"
        if [ "$(conf_map LAYOUT "$b")" = releases ]; then env="$(dirname "$d")/shared/wp-config-env.php"
        else env="$d/wp-config-env.php"; fi
        echo "$env $(pool_user "$b")"
      done
    )
  done
}

# --- run ------------------------------------------------------------------------------
results="$(
  audit_nginx_test; audit_nginx_tls; audit_nginx_tokens; audit_nginx_gzip; audit_nginx_logformat
  audit_nginx_catchall; audit_nginx_symlinks
  audit_os_autoreboot; audit_os_reboot_pending; audit_os_journald; audit_os_failed_units; audit_os_php_cli
  audit_php_pool_users; site_secrets | audit_php_secrets
  audit_mail_conf; audit_mail_readers
  audit_security; audit_ssh_admin; audit_node_root; audit_backups
)"

printf '%s\n' "$results" | while IFS=$'\t' read -r s id msg; do
  [ "$FAIL_ONLY" = 1 ] && [ "$s" = PASS ] && continue
  case "$s" in PASS) c=32 ;; WARN) c=33 ;; *) c=31 ;; esac
  printf '\033[%sm%-4s\033[0m  %-16s %s\n' "$c" "$s" "$id" "$msg"
done
p="$(printf '%s\n' "$results" | grep -c '^PASS')"; w="$(printf '%s\n' "$results" | grep -c '^WARN')"; f="$(printf '%s\n' "$results" | grep -c '^FAIL')"
echo "-- ${p} pass, ${w} warn, ${f} fail"
[ "$f" -eq 0 ]
