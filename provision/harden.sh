#!/bin/bash
# deploy-kit — WordPress hardening for an ALREADY-PROVISIONED droplet.
#
# provision-base.sh only runs on fresh boxes. Every droplet in the fleet is already
# provisioned and its vhosts have been edited in place by certbot, so hardening has to
# be applied additively to a running box. That is what this script does.
#
# What it installs:
#   /etc/nginx/conf.d/00-cloudflare-realip.conf   real visitor IPs behind Cloudflare
#   /etc/nginx/conf.d/wp-security.conf            wp-login.php rate limiting
#   /etc/nginx/snippets/wp-hardening.conf         xmlrpc.php block (per-vhost include)
#   /etc/nginx/conf.d/00-cloudflare-geo.conf      $from_cloudflare (1 = request came via CF)
#   /etc/nginx/snippets/cloudflare-only.conf      444 anything not via CF (opt-in include)
#   /etc/nginx/snippets/wp-microcache.conf        stale/lock/background-update for the
#                                                 FastCGI micro-cache (opt-in include)
#   /etc/nginx/snippets/scanner-block.conf        reject scanner traffic before PHP
#                                                 (baseline; inserted with --scanner-block)
#
# The opt-in snippets are installed but NOT inserted into any vhost unless asked —
# each is a per-site decision (see the comments in nginx/*.snippet.conf). Installing
# them is inert. scanner-block is part of the fleet baseline
# (docs/droplet-cache-convention.md); --scanner-block inserts it after the
# wp-hardening include in every vhost this run touches (respects --only).
#
# ORDER MATTERS. Cloudflare real-IP must be in place BEFORE rate limiting, or the limit
# keys on the Cloudflare edge IP instead of the visitor. On a proxied site that buckets
# every visitor into ~20 shared keys: it throttles real users and barely touches an
# attacker. Both land in the same run here, so don't split them.
#
# Idempotent. Safe to re-run — that is also how you refresh the Cloudflare ranges.
#
#   Usage:
#     harden.sh --check              report current state, change nothing
#     harden.sh --only <vhost>       apply, but patch only that one vhost (staging first)
#     harden.sh                      apply to all enabled vhosts
#     harden.sh --scanner-block [--only <vhost>]
#                                    also include snippets/scanner-block.conf
#
set -euo pipefail

KIT="${KIT:-/opt/deploy-kit}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/nginx-bak/harden-${STAMP}"
ONLY=""
CHECK=0
SCANNER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --only)  ONLY="${2:-}"; shift ;;
    --scanner-block) SCANNER=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

log(){ echo ">> $*"; }

# --- report current state -----------------------------------------------------------
if [ "$CHECK" = "1" ]; then
  echo "=== conf.d ==="
  for f in 00-cloudflare-realip.conf 00-cloudflare-geo.conf wp-security.conf; do
    if [ -f "/etc/nginx/conf.d/$f" ]; then echo "  PRESENT  $f"; else echo "  MISSING  $f"; fi
  done
  echo "=== snippets ==="
  for f in wp-hardening.conf wp-microcache.conf cloudflare-only.conf scanner-block.conf; do
    if [ -f "/etc/nginx/snippets/$f" ]; then echo "  PRESENT  $f"; else echo "  MISSING  $f"; fi
  done
  echo "=== vhosts including the opt-in snippets ==="
  for f in wp-microcache.conf cloudflare-only.conf scanner-block.conf; do
    grep -l "snippets/$f" /etc/nginx/sites-enabled/* 2>/dev/null | sed "s|^|  $f  |" || true
  done
  echo "=== vhosts including the snippet ==="
  for v in /etc/nginx/sites-enabled/*; do
    [ -e "$v" ] || continue
    case "$(basename "$v")" in 000-drop-default) continue ;; esac
    if grep -q "wp-hardening.conf" "$v" 2>/dev/null; then
      echo "  INCLUDED  $(basename "$v")"
    else
      echo "  no        $(basename "$v")"
    fi
  done
  exit 0
fi

mkdir -p "$BACKUP" /etc/nginx/snippets
log "backups -> $BACKUP"

# --- 1. Cloudflare real-IP ----------------------------------------------------------
# Fetched live rather than hardcoded; Cloudflare changes these ranges. Re-running this
# script is the refresh mechanism. If the fetch fails we keep whatever is already
# installed rather than writing a truncated trust list — a short trust list silently
# turns real-IP restoration off for the ranges it drops.
log "fetching Cloudflare ranges"
CF4="$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v4 || true)"
CF6="$(curl -fsS --max-time 20 https://www.cloudflare.com/ips-v6 || true)"

n4="$(printf '%s\n' "$CF4" | grep -cE '^[0-9.]+/[0-9]+$' || true)"
n6="$(printf '%s\n' "$CF6" | grep -cE '^[0-9a-fA-F:]+/[0-9]+$' || true)"

if [ "${n4:-0}" -lt 10 ] || [ "${n6:-0}" -lt 4 ]; then
  if [ -f /etc/nginx/conf.d/00-cloudflare-realip.conf ]; then
    log "WARN: fetch looked wrong (v4=$n4 v6=$n6) — keeping existing file"
  else
    echo "ERROR: could not fetch Cloudflare ranges and none installed. Aborting." >&2
    exit 1
  fi
else
  [ -f /etc/nginx/conf.d/00-cloudflare-realip.conf ] && \
    cp /etc/nginx/conf.d/00-cloudflare-realip.conf "$BACKUP/"
  {
    echo "# deploy-kit — generated by provision/harden.sh on ${STAMP}. Do not edit;"
    echo "# re-run harden.sh to refresh. Source: cloudflare.com/ips-v4 and /ips-v6."
    echo "#"
    echo "# Without this, \$remote_addr on a Cloudflare-proxied vhost is the Cloudflare"
    echo "# edge IP. That breaks rate limiting (everyone shares ~20 keys) and makes the"
    echo "# access log useless for incident response — you cannot identify an attacker."
    printf '%s\n' "$CF4" | grep -E '^[0-9.]+/[0-9]+$'          | sed 's/^/set_real_ip_from /; s/$/;/'
    printf '%s\n' "$CF6" | grep -E '^[0-9a-fA-F:]+/[0-9]+$'    | sed 's/^/set_real_ip_from /; s/$/;/'
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
  } > /etc/nginx/conf.d/00-cloudflare-realip.conf
  log "cloudflare real-ip installed (v4=$n4 v6=$n6)"

  # Same ranges, second use: was this request delivered BY Cloudflare? Keyed on
  # $realip_remote_addr — the TCP peer — because real-ip has already rewritten
  # $remote_addr to the visitor, who is never in these ranges. Consumed only by
  # snippets/cloudflare-only.conf; defining the variable alone changes nothing.
  [ -f /etc/nginx/conf.d/00-cloudflare-geo.conf ] && \
    cp /etc/nginx/conf.d/00-cloudflare-geo.conf "$BACKUP/"
  {
    echo "# deploy-kit — generated by provision/harden.sh on ${STAMP}. Do not edit;"
    echo "# re-run harden.sh to refresh. Source: cloudflare.com/ips-v4 and /ips-v6."
    echo "geo \$realip_remote_addr \$from_cloudflare {"
    echo "    default 0;"
    echo "    # Loopback: deploy-kit's smoke test and on-box checks reach the site on"
    echo "    # 127.0.0.1 with --resolve. Without these, cloudflare-only.conf fails every deploy."
    echo "    127.0.0.0/8 1;"
    echo "    ::1 1;"
    printf '%s\n' "$CF4" | grep -E '^[0-9.]+/[0-9]+$'       | sed 's/^/    /; s/$/ 1;/'
    printf '%s\n' "$CF6" | grep -E '^[0-9a-fA-F:]+/[0-9]+$' | sed 's/^/    /; s/$/ 1;/'
    echo "}"
  } > /etc/nginx/conf.d/00-cloudflare-geo.conf
  log "cloudflare geo installed"
fi

# Safe on non-proxied boxes too: nginx only honours CF-Connecting-IP from an address in
# the trust list above, so a direct client cannot spoof its way past it.

# --- 2. login rate limiting ---------------------------------------------------------
[ -f /etc/nginx/conf.d/wp-security.conf ] && cp /etc/nginx/conf.d/wp-security.conf "$BACKUP/"
cp "$KIT/nginx/wp-security.conf.template" /etc/nginx/conf.d/wp-security.conf
log "wp-security.conf installed"

# --- 3. snippets + per-vhost include (hardening only) --------------------------------
# Back up before overwriting: vhosts include these, so a rollback must RESTORE a
# snippet that existed, never delete it — a missing included file fails `nginx -t`
# for every site on the box.
for f in wp-hardening wp-microcache cloudflare-only scanner-block; do
  [ -f "/etc/nginx/snippets/$f.conf" ] && cp "/etc/nginx/snippets/$f.conf" "$BACKUP/snippet-$f.conf"
  cp "$KIT/nginx/$f.snippet.conf" "/etc/nginx/snippets/$f.conf"
done
log "snippets installed: wp-hardening (+ opt-in wp-microcache, cloudflare-only, scanner-block)"

# Iterate sites-ENABLED, not sites-available, and resolve to the file nginx actually
# loads. This is load-bearing: on three of the four ARTHOUSE droplets, sites-enabled
# holds REAL FILES rather than symlinks, and they have drifted from their
# sites-available namesakes (CBA production by 2 lines, its staging by 22). Patching
# sites-available there would edit a file nginx never reads, report success, and change
# nothing — a silent no-op. Only Shucked uses symlinks, which is why an earlier version
# of this script appeared to work.
#
# readlink -f resolves a symlink to its target and returns a real path unchanged, so
# this handles both layouts.
: > "$BACKUP/manifest.txt"
patched=0
for link in /etc/nginx/sites-enabled/*; do
  [ -e "$link" ] || continue
  base="$(basename "$link")"
  case "$base" in 000-drop-default) continue ;; esac
  [ -n "$ONLY" ] && [ "$base" != "$ONLY" ] && continue

  v="$(readlink -f "$link")"
  [ -f "$v" ] || { log "SKIP $base — cannot resolve to a real file"; continue; }

  grep -q "wp-hardening.conf" "$v" && { log "already patched: $base"; continue; }

  cp "$v" "$BACKUP/$base"
  printf '%s\t%s\n' "$base" "$v" >> "$BACKUP/manifest.txt"
  # Insert the include immediately after every `server {` opening line. It must precede
  # the generic `location ~ \.php$` — nginx matches regex locations in order of
  # appearance, so first-in-file wins.
  awk '
    /^[[:space:]]*server[[:space:]]*\{/ {
      print
      print "    include snippets/wp-hardening.conf;"
      next
    }
    { print }
  ' "$v" > "${v}.harden.tmp"
  mv "${v}.harden.tmp" "$v"
  patched=$((patched+1))
  log "patched: $base"
done
log "vhosts patched: $patched"

# --- 3b. scanner-block include (opt-in flag) -----------------------------------------
if [ "$SCANNER" = "1" ]; then
  # shellcheck disable=SC1091
  source "$KIT/provision/lib/vhost.sh"
  for link in /etc/nginx/sites-enabled/*; do
    [ -e "$link" ] || continue
    base="$(basename "$link")"
    case "$base" in 000-drop-default) continue ;; esac
    [ -n "$ONLY" ] && [ "$base" != "$ONLY" ] && continue
    v="$(readlink -f "$link")"
    [ -f "$v" ] || continue
    # Back up once per run: step 3 may already have saved this vhost.
    if ! grep -q "^${base}"$'\t' "$BACKUP/manifest.txt"; then
      cp "$v" "$BACKUP/$base"; printf '%s\t%s\n' "$base" "$v" >> "$BACKUP/manifest.txt"
    fi
    log "scanner-block: $base — $(add_include_after_hardening "$v" scanner-block)"
  done
fi

# --- 4. validate, or roll everything back -------------------------------------------
if nginx -t 2>&1; then
  systemctl reload nginx
  log "OK — nginx reloaded. Backups kept at $BACKUP"
else
  log "nginx -t FAILED — rolling back"
  # conf.d files restore to a fixed location; vhosts restore to wherever they actually
  # came from, which manifest.txt recorded. Restoring them to sites-available would
  # leave the live sites-enabled copies broken on the boxes that use real files.
  for b in 00-cloudflare-realip.conf 00-cloudflare-geo.conf wp-security.conf; do
    [ -f "$BACKUP/$b" ] && cp "$BACKUP/$b" "/etc/nginx/conf.d/$b"
  done
  if [ -f "$BACKUP/manifest.txt" ]; then
    while IFS=$'\t' read -r b path; do
      [ -n "$b" ] && [ -f "$BACKUP/$b" ] && cp "$BACKUP/$b" "$path"
    done < "$BACKUP/manifest.txt"
  fi
  # Files this run created rather than replaced won't be in the backup dir; remove them.
  [ -f "$BACKUP/wp-security.conf" ] || rm -f /etc/nginx/conf.d/wp-security.conf
  [ -f "$BACKUP/00-cloudflare-realip.conf" ] || rm -f /etc/nginx/conf.d/00-cloudflare-realip.conf
  [ -f "$BACKUP/00-cloudflare-geo.conf" ] || rm -f /etc/nginx/conf.d/00-cloudflare-geo.conf
  for f in wp-hardening wp-microcache cloudflare-only scanner-block; do
    if [ -f "$BACKUP/snippet-$f.conf" ]; then
      cp "$BACKUP/snippet-$f.conf" "/etc/nginx/snippets/$f.conf"
    else
      rm -f "/etc/nginx/snippets/$f.conf"
    fi
  done
  nginx -t && systemctl reload nginx
  echo "ERROR: hardening reverted. Nothing changed. See output above." >&2
  exit 1
fi

cat <<'EOF'

VERIFY (from your laptop, not the box):
  curl -o /dev/null -w '%{http_code}\n' -X POST https://<site>/xmlrpc.php      # want 403
  curl -o /dev/null -w '%{http_code}\n' -X POST https://<site>/wp/xmlrpc.php   # want 403
  for i in $(seq 1 30); do curl -o /dev/null -s -w '%{http_code} ' https://<site>/wp/wp-login.php; done
                                                                              # want 200s then 429s
REMEMBER: rate limiting does not stop an attacker who already has the password.
2FA on the shared admin account is the control that would have stopped CBA.
EOF
