#!/bin/bash
# deploy-kit — apply the host baseline to a droplet, fresh or already running. As root.
#
#     baseline.sh [--reboot-time HH:MM] [--php-memory 256M] [--php-upload 64M] [--journal 500M]
#                 [--swap 2G] [--no-firewall]
#
# What it owns (provision/audit.sh checks the same list):
#   nginx.conf      TLS 1.2+ only, server_tokens off, gzip for text assets, `log_format
#                   timed` on the access log (cache status + timings)
#   00-catchall     default_server that refuses unknown hosts at the handshake
#   apt             unattended-upgrades reboots when required (default 09:00 UTC), drops
#                   old kernels, and takes PHP patches from the ondrej PPA when it is used
#   journald        size cap
#   PHP-FPM         conf.d/99-local.ini: memory_limit and upload limits
#   swap            a swapfile (--swap, default 2G; 0 skips) when the box has none,
#                   and vm.swappiness=10
#   firewall        ufw: inbound denied except SSH and HTTP/HTTPS (SSH opened before enable);
#                   fail2ban on with Ubuntu's sshd jail. Skip with --no-firewall.
#
# Idempotent: a file is written only when its content differs, so a second run reports
# every item "unchanged". Everything it touches is backed up first; nginx -t (warnings
# included) and php-fpm -t must pass before anything reloads, or every file is restored.
set -euo pipefail

KIT="${KIT:-/opt/deploy-kit}"
# shellcheck disable=SC1091
source "$KIT/provision/lib/baseline.sh"
log(){ echo ">> $*"; }

REBOOT_AT="09:00"; PHP_MEM="256M"; PHP_UP="64M"; JOURNAL="500M"; SWAP="2G"; FIREWALL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --reboot-time) REBOOT_AT="${2:?}"; shift ;;
    --php-memory)  PHP_MEM="${2:?}"; shift ;;
    --php-upload)  PHP_UP="${2:?}"; shift ;;
    --journal)     JOURNAL="${2:?}"; shift ;;
    --swap)        SWAP="${2:?}"; shift ;;
    --no-firewall) FIREWALL=0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p /root/baseline-bak
BAK="$(mktemp -d "/root/baseline-bak/${STAMP}-XXXX")"
: > "$BAK/manifest.txt"
log "backups -> $BAK"
CHANGED_NGINX=0; CHANGED_FPM=0

backup() {  # backup <path>: remember a file (or that it did not exist) so restore() can undo
  local p="$1" b
  grep -qxF "$p" "$BAK/manifest.txt" && return 0
  echo "$p" >> "$BAK/manifest.txt"
  b="$BAK/files$p"; mkdir -p "$(dirname "$b")"
  if [ -e "$p" ] || [ -L "$p" ]; then cp -a "$p" "$b"; else : > "$b.absent"; fi
}
restore() {
  log "RESTORING every file from $BAK"
  local p
  while read -r p; do
    if [ -e "$BAK/files$p.absent" ]; then rm -f "$p"; else cp -a "$BAK/files$p" "$p"; fi
  done < "$BAK/manifest.txt"
}

# write_if_changed <dest> : content on stdin. Prints the outcome for the log.
write_if_changed() {
  local dest="$1" tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; echo "unchanged  $dest"; return 1; fi
  backup "$dest"; mkdir -p "$(dirname "$dest")"; install -m 0644 "$tmp" "$dest"; rm -f "$tmp"
  echo "written    $dest"; return 0
}

# --- nginx.conf ---------------------------------------------------------------------
NC=/etc/nginx/nginx.conf
backup "$NC"
while IFS=$'\t' read -r name value; do
  r="$(nginx_set "$NC" "$name" "$value")"; echo "${r}  nginx.conf ${name}"
  [ "$r" = unchanged ] || CHANGED_NGINX=1
done < <(baseline_nginx_directives)
r="$(nginx_ensure_log_format "$NC")"; echo "${r}  nginx.conf log_format timed"; [ "$r" = present ] || CHANGED_NGINX=1
r="$(nginx_set "$NC" access_log "/var/log/nginx/access.log timed")"; echo "${r}  nginx.conf access_log"
[ "$r" = unchanged ] || CHANGED_NGINX=1

# --- catch-all default_server ---------------------------------------------------------
if render_catchall | write_if_changed /etc/nginx/sites-available/00-catchall; then CHANGED_NGINX=1; fi
if [ "$(readlink /etc/nginx/sites-enabled/00-catchall 2>/dev/null)" != /etc/nginx/sites-available/00-catchall ]; then
  backup /etc/nginx/sites-enabled/00-catchall
  ln -sfn /etc/nginx/sites-available/00-catchall /etc/nginx/sites-enabled/00-catchall
  echo "linked     sites-enabled/00-catchall"; CHANGED_NGINX=1
fi
# provision-base's port-80-only default would be a second default_server on 80.
if [ -e /etc/nginx/sites-enabled/000-drop-default ]; then
  backup /etc/nginx/sites-enabled/000-drop-default
  rm -f /etc/nginx/sites-enabled/000-drop-default
  echo "removed    sites-enabled/000-drop-default (superseded by 00-catchall)"; CHANGED_NGINX=1
fi

# --- unattended-upgrades --------------------------------------------------------------
ORIGIN=""
if grep -rqs 'ppa.launchpadcontent.net/ondrej/php' /etc/apt/sources.list.d/; then
  ORIGIN="o=LP-PPA-ondrej-php,a=$(. /etc/os-release && echo "$VERSION_CODENAME")"
fi
render_unattended "$REBOOT_AT" "$ORIGIN" | write_if_changed /etc/apt/apt.conf.d/52unattended-local || true

# --- journald ---------------------------------------------------------------------------
if render_journald "$JOURNAL" | write_if_changed /etc/systemd/journald.conf.d/size.conf; then
  systemctl restart systemd-journald && journalctl --vacuum-size="$JOURNAL" >/dev/null 2>&1 || true
fi

# --- PHP-FPM ----------------------------------------------------------------------------
for d in /etc/php/*/fpm; do
  [ -d "$d" ] || continue
  if render_php_local "$PHP_MEM" "$PHP_UP" | write_if_changed "$d/conf.d/99-local.ini"; then CHANGED_FPM=1; fi
done

# --- swap -------------------------------------------------------------------------------
[ "$SWAP" = 0 ] || apply_swap "$SWAP" | sed 's/^/   /'

# --- firewall + fail2ban ----------------------------------------------------------------
[ "$FIREWALL" = 1 ] && apply_firewall | sed 's/^/   /'

# --- validate, then reload ----------------------------------------------------------------
if [ "$CHANGED_FPM" = 1 ]; then
  for v in /etc/php/*/fpm; do
    ver="$(basename "$(dirname "$v")")"
    "php-fpm${ver}" -t >/dev/null 2>&1 || { restore; echo "php-fpm${ver} -t FAILED — every file restored" >&2; exit 1; }
    systemctl reload "php${ver}-fpm"
  done
fi
if [ "$CHANGED_NGINX" = 1 ]; then
  out="$(nginx -t 2>&1)" || { restore; echo "nginx -t FAILED — every file restored:" >&2; echo "$out" >&2; exit 1; }
  if printf '%s' "$out" | grep -q '\[warn\]'; then
    restore; echo "nginx -t passed WITH warnings — every file restored:" >&2; echo "$out" >&2; exit 1
  fi
  systemctl reload nginx
fi

echo
log "baseline applied. Audit:"
bash "$KIT/provision/audit.sh" --fail-only || true
