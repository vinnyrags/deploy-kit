#!/bin/bash
# deploy-kit — outbound mail for a WordPress droplet, via msmtp.
#
# Every droplet in the fleet ships with sendmail_path pointing at
# /usr/sbin/sendmail and no MTA behind it, so PHP mail() — and therefore
# wp_mail() — fails silently. Password resets, form notifications and admin
# notices all vanish with no error the user ever sees. This installs the relay
# that fixes it.
#
# ---------------------------------------------------------------------------
# THE PERMISSION BUG THIS EXISTS TO PREVENT
#
# msmtp's config holds a password, so the obvious instinct is 0600 root:root.
# That is wrong here and fails in the most misleading way available:
#
#   PHP-FPM runs as www-data. A root-only config means every WEB-initiated
#   email fails with "account default not found: no configuration file
#   available" — while every `wp-cli` send over SSH succeeds, because root can
#   read the file.
#
# So the box looks healthy from the terminal and is broken for real users.
# vincentragosta.io sat like that from 2026-05-11 to 2026-08-28: msmtp.log was
# full of exitcode=EX_OK entries, all of them root's, while WordPress issued
# password-reset keys with no send at all.
#
# The file must be 0640 root:www-data. msmtp only rejects a config that is
# group/world WRITABLE; group-readable is fine.
#
# Corollary: NEVER verify mail with `wp eval` over SSH. That is the one context
# that works while the site is broken. Use --test-to, which sends as www-data.
# ---------------------------------------------------------------------------
#
# Deliverability note: the From address must be on a domain the provider has
# verified, or the message is refused (Resend) or silently rewritten to the
# authenticated account (Gmail). Verify the DOMAIN, not a single sender
# address — domain verification is what yields a DKIM signature aligned to the
# site's own domain, which is what DMARC actually checks.
#
#   Usage:
#     mail.sh --check
#     mail.sh --provider resend --key-file /root/.resend_key --from noreply@example.com
#     mail.sh --host smtp.example.net --port 587 --user u --key-file F --from a@example.com
#     mail.sh --test-to you@example.com          # verify only, change nothing
#
#   The API key is read from a FILE or stdin, never an argument — arguments are
#   visible to any user via ps.
#
# ---------------------------------------------------------------------------
# DIGITALOCEAN BLOCKS OUTBOUND SMTP ON SOME ACCOUNTS
#
# Symptom: this script appears to hang, then msmtp.log shows
#   errormsg='cannot connect to smtp.resend.com, port 587: Connection timed out'
#   exitcode=EX_TEMPFAIL
#
# It is not a config or credential fault — the packets never leave. DO blocks
# 25/465/587 outbound on some accounts and will lift it on request via a support
# ticket. Resend also listens on 2587, which is usually open, and that is the
# faster fix:
#
#   --host smtp.resend.com --port 2587 --user resend
#
# This is per-account, not fleet-wide: ellenharvey-prod-01 (2026-09-03) has
# 25/465/587 blocked and 2587 open, while 174.138.70.29 sends happily on 587.
# Check before assuming, from the droplet itself:
#
#   for p in 587 465 2587 25; do
#     timeout 8 bash -c "echo > /dev/tcp/smtp.resend.com/$p" 2>/dev/null \
#       && echo "OPEN $p" || echo "BLOCKED $p"
#   done

set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/mail-backups/${STAMP}"
CONF=/etc/msmtprc
LOGFILE=/var/log/msmtp.log

# PORT starts empty so an explicit --port survives the provider defaults below.
PROVIDER=""; HOST=""; PORT=""; USERNAME=""; KEYFILE=""; FROM=""; TEST_TO=""; CHECK=0

log(){ echo ">> $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)     CHECK=1 ;;
    --provider)  PROVIDER="${2:-}"; shift ;;
    --host)      HOST="${2:-}"; shift ;;
    --port)      PORT="${2:-}"; shift ;;
    --user)      USERNAME="${2:-}"; shift ;;
    --key-file)  KEYFILE="${2:-}"; shift ;;
    --from)      FROM="${2:-}"; shift ;;
    --test-to)   TEST_TO="${2:-}"; shift ;;
    *) die "unknown arg: $1" ;;
  esac
  shift
done

# --- report current state -----------------------------------------------------------
if [ "$CHECK" = "1" ]; then
  echo "=== MTA ==="
  if command -v msmtp >/dev/null; then echo "  PRESENT  msmtp ($(readlink -f /usr/sbin/sendmail 2>/dev/null || echo 'sendmail not linked'))"
  else echo "  MISSING  no msmtp"; fi
  echo "  sendmail_path: $(php -r 'echo ini_get("sendmail_path") ?: "(empty)";' 2>/dev/null || echo '?')"
  echo "=== config ==="
  if [ -f "$CONF" ]; then
    perms="$(stat -c '%a %U:%G' "$CONF")"
    echo "  PRESENT  $CONF  [$perms]"
    case "$perms" in
      "640 root:www-data") echo "  OK       readable by PHP-FPM" ;;
      *) echo "  BROKEN   must be 640 root:www-data — web mail is failing silently" ;;
    esac
    echo "  account default: $(grep '^account default' "$CONF" 2>/dev/null || echo '(none)')"
  else
    echo "  MISSING  $CONF"
  fi
  echo "=== can www-data actually send? ==="
  if sudo -u www-data test -r "$CONF" 2>/dev/null; then echo "  OK       www-data can read the config"
  else echo "  BROKEN   www-data CANNOT read the config"; fi
  exit 0
fi

# --- verify-only --------------------------------------------------------------------
if [ -n "$TEST_TO" ] && [ -z "$FROM" ]; then
  [ -f "$CONF" ] || die "no $CONF to test"
  log "sending as www-data (the PHP-FPM identity) to $TEST_TO"
  sudo -u www-data /usr/sbin/sendmail -t -i <<EOF
To: ${TEST_TO}
Subject: [deploy-kit] mail check from $(hostname)

Sent as www-data. If this arrives, web-initiated mail works on this host.
Confirm the From header and that DKIM aligns to this site's own domain.
EOF
  log "queued — confirm in $LOGFILE and in the recipient's headers"
  tail -1 "$LOGFILE" 2>/dev/null || true
  exit 0
fi

# --- resolve provider ---------------------------------------------------------------
# The provider supplies defaults; it must not clobber anything given explicitly.
# This block runs AFTER argument parsing, so assigning PORT unconditionally here
# silently discarded a --port the caller had already passed. That cost a debugging
# cycle on ellenharvey-prod-01, where 587 is blocked and 2587 is required.
case "$PROVIDER" in
  resend) HOST="${HOST:-smtp.resend.com}"; PORT="${PORT:-587}"; USERNAME="${USERNAME:-resend}" ;;
  "")     : ;;
  *)      die "unknown provider: $PROVIDER (known: resend)" ;;
esac

PORT="${PORT:-587}"

[ -n "$HOST" ]     || die "--host or --provider required"
[ -n "$USERNAME" ] || die "--user required"
[ -n "$FROM" ]     || die "--from required (must be on a domain verified with the provider)"

# Key from file or stdin — never an argument, which ps would expose.
if [ -n "$KEYFILE" ]; then
  [ -f "$KEYFILE" ] || die "key file not found: $KEYFILE"
  KEY="$(cat "$KEYFILE")"
else
  [ -t 0 ] && die "no --key-file given and stdin is a terminal; pipe the key in"
  KEY="$(cat)"
fi
[ -n "$KEY" ] || die "empty key"

# --- install ------------------------------------------------------------------------
if ! command -v msmtp >/dev/null; then
  log "installing msmtp-mta"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq msmtp msmtp-mta >/dev/null
fi
# msmtp-mta provides /usr/sbin/sendmail, which is what PHP's sendmail_path calls.
[ -e /usr/sbin/sendmail ] || die "/usr/sbin/sendmail missing — is msmtp-mta installed?"

mkdir -p "$BACKUP"
if [ -f "$CONF" ]; then
  cp -a "$CONF" "$BACKUP/msmtprc"
  log "backed up existing config -> $BACKUP/msmtprc"
fi

umask 077
cat > "${CONF}.new" <<EOF
# Managed by deploy-kit provision/mail.sh — generated ${STAMP}.
#
# PERMISSIONS ARE LOAD-BEARING: 0640 root:www-data. PHP-FPM runs as www-data;
# a root-only 0600 file makes every WEB-initiated email fail silently while
# root wp-cli sends keep succeeding. Verify with:
#   sudo -u www-data /usr/sbin/sendmail -t -i
# never with \`wp eval\` over SSH.
#
# The From address must be on a domain verified with the provider, or the
# message is refused or silently rewritten.

defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ${LOGFILE}

account        primary
host           ${HOST}
port           ${PORT}
from           ${FROM}
user           ${USERNAME}
password       ${KEY}

account default : primary
EOF

chown root:www-data "${CONF}.new"
chmod 640 "${CONF}.new"
mv "${CONF}.new" "$CONF"
log "wrote $CONF [$(stat -c '%a %U:%G' "$CONF")]"

# msmtp appends to its log as www-data, so the log needs group write too.
touch "$LOGFILE"
chown root:www-data "$LOGFILE"
chmod 660 "$LOGFILE"
log "log $LOGFILE [$(stat -c '%a %U:%G' "$LOGFILE")]"

# --- verify as the web user, not as root --------------------------------------------
sudo -u www-data test -r "$CONF" || die "www-data still cannot read $CONF"
log "www-data can read the config"

if [ -n "$TEST_TO" ]; then
  log "test send as www-data -> $TEST_TO"
  sudo -u www-data /usr/sbin/sendmail -t -i <<EOF
From: ${FROM}
To: ${TEST_TO}
Subject: [deploy-kit] mail configured on $(hostname)

Relay: ${HOST}. Sent as www-data, so this proves the path WordPress uses.
Check the headers for dkim=pass aligned to this site's own domain.
EOF
  sleep 2
  tail -1 "$LOGFILE" | sed 's/^/   /'
fi

cat <<EOF

DONE. Rollback: cp $BACKUP/msmtprc $CONF && chown root:www-data $CONF && chmod 640 $CONF

VERIFY (not from a root shell):
  sudo -u www-data /usr/sbin/sendmail -t -i <<< \$'To: you@example.com\nSubject: t\n\nbody'
  then read the DELIVERED headers — a 250 from the relay only proves it was accepted:
    dkim=pass  header.i=@<your-domain>
    spf=pass
    dmarc=pass header.from=<your-domain>
EOF
