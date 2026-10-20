#!/bin/bash
# deploy-kit — nightly off-site backups of a WordPress site's database and uploads,
# via restic to any S3-compatible bucket (Backblaze B2's free tier by default).
#
# A droplet with no backups loses everything to one bad `rm`, one compromised plugin
# or one DigitalOcean account problem. This puts an encrypted, deduplicated copy
# somewhere else, on a different provider, every night — and fails LOUDLY.
#
# ---------------------------------------------------------------------------
# WHY THE RESULT LINE MATTERS
#
# The fleet's previous "backup" was a cron that copied a file which no longer
# existed, failed every night, and still logged "Backup — data-<date>.db.gz".
# A success line printed after a failed step is worse than no backup at all:
# it is the reason nobody looks. So this script runs under `set -euo pipefail`
# (a failed `wp db export` fails the whole pipe), and it prints exactly one of
#
#   BACKUP-RESULT: ok
#   BACKUP-RESULT: fail (<reason>)
#
# as its last line, and exits non-zero on fail. systemd records the exit status,
# so `systemctl status deploy-kit-backup@<site>` shows a failed unit in red.
# ---------------------------------------------------------------------------
#
#   Usage:
#     backup.sh --install <site.conf>   install restic + the systemd timer for this site
#     backup.sh --init    <site.conf>   create the restic repository (once)
#     backup.sh --run     <site.conf>   back up now (what the timer runs)
#     backup.sh --verify  <site.conf>   restic check, reading a 5% sample of the data
#     backup.sh --list    <site.conf>   list snapshots
#
#   Site conf keys (in /etc/deploy-kit/<site>.conf, alongside the deploy keys):
#     BACKUP_BRANCH=main               which environment to back up (DEPLOY_DIR key)
#     BACKUP_ENV_FILE=/root/.restic-env  credentials (see below); default shown
#     BACKUP_KEEP="--keep-daily 7 --keep-weekly 4 --keep-monthly 6"   retention
#
#   Credentials file (0600 root), never in the repo or the site conf:
#     RESTIC_REPOSITORY=s3:https://s3.<region>.backblazeb2.com/<bucket>/<site>
#     RESTIC_PASSWORD_FILE=/root/.restic-pass
#     AWS_ACCESS_KEY_ID=<B2 keyID>
#     AWS_SECRET_ACCESS_KEY=<B2 applicationKey>
#
#   The restic password and the B2 key MUST also live somewhere off this box (a
#   password manager). The repository is encrypted: if the droplet is lost and the
#   password was only on the droplet, the backups are unreadable.
#
#   B2 free tier: 10 GB stored, no card required. Set Caps & Alerts to $0 in the
#   B2 account so storage growth can never turn into a bill — uploads fail instead,
#   and this script reports that as fail.

set -euo pipefail

MODE="${1:-}"; CONF="${2:-}"
KIT="${DEPLOY_KIT_DIR:-/opt/deploy-kit}"

die() { trap - EXIT; echo "BACKUP-RESULT: fail ($*)"; exit 1; }
log() { echo ">> $*"; }

[ -n "$MODE" ] && [ -n "$CONF" ] || { sed -n '25,31p' "$0"; exit 2; }
[ -r "$CONF" ] || die "site conf not readable: $CONF"

# shellcheck disable=SC1090
source "$CONF"
SITE="$(basename "$CONF" .conf)"
BRANCH="${BACKUP_BRANCH:-main}"
ENV_FILE="${BACKUP_ENV_FILE:-/root/.restic-env}"
KEEP="${BACKUP_KEEP:---keep-daily 7 --keep-weekly 4 --keep-monthly 6}"

# shellcheck disable=SC1091
source "$KIT/deploy/lib/common.sh"
DEST="$(conf_map DEPLOY_DIR "$BRANCH")"
[ -n "$DEST" ] || die "no DEPLOY_DIR[$BRANCH] in $CONF"

load_creds() {
  [ -r "$ENV_FILE" ] || die "credentials file missing: $ENV_FILE"
  [ "$(stat -c %a "$ENV_FILE")" = 600 ] || die "$ENV_FILE must be mode 600"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  [ -n "${RESTIC_REPOSITORY:-}" ] || die "RESTIC_REPOSITORY not set in $ENV_FILE"
}

# Ask WordPress where it keeps uploads rather than guessing from the docroot, so
# this keeps working when the site moves to a releases/ + shared/ layout.
wp_() { wp --path="$DEST/wp" --allow-root --quiet "$@"; }

case "$MODE" in
  --install)
    command -v restic >/dev/null || { log "installing restic"; apt-get install -y -qq restic >/dev/null; }
    restic version
    install -m 0644 "$KIT/provision/systemd/deploy-kit-backup@.service" /etc/systemd/system/
    install -m 0644 "$KIT/provision/systemd/deploy-kit-backup@.timer"   /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now "deploy-kit-backup@${SITE}.timer"
    systemctl list-timers "deploy-kit-backup@${SITE}.timer" --no-pager
    log "installed. Next: write $ENV_FILE (0600), then: $0 --init $CONF && $0 --run $CONF"
    ;;

  --init)
    load_creds
    if restic cat config >/dev/null 2>&1; then
      log "repository already exists: $RESTIC_REPOSITORY"
    else
      restic init
    fi
    ;;

  --run)
    load_creds
    trap 'rc=$?; [ "$rc" -eq 0 ] || echo "BACKUP-RESULT: fail (exit $rc)"' EXIT

    uploads="$(wp_ eval 'echo wp_upload_dir()["basedir"];')"
    # Under LAYOUT=releases WordPress reports current/wp-content/uploads, which is a
    # symlink into shared/. restic stores a symlink given as a backup path AS a symlink:
    # without resolving it, every nightly "uploads" snapshot would hold one link and no
    # files. A no-op for an in-place docroot.
    uploads="$(readlink -f "$uploads")"
    [ -d "$uploads" ] || die "uploads dir not found: $uploads"

    log "database → restic (${SITE}, ${BRANCH})"
    wp_ db export - --single-transaction --quick \
      | restic backup --stdin --stdin-filename "${SITE}-db.sql" --tag "$SITE" --tag db --host "$SITE"

    log "uploads → restic ($uploads)"
    restic backup "$uploads" --tag "$SITE" --tag uploads --host "$SITE"

    log "retention: $KEEP"
    # shellcheck disable=SC2086
    restic forget --host "$SITE" --group-by host,tags $KEEP --prune

    trap - EXIT
    echo "BACKUP-RESULT: ok"
    ;;

  --verify)
    load_creds
    restic check --read-data-subset=5%
    echo "BACKUP-RESULT: ok (verified)"
    ;;

  --list)
    load_creds
    restic snapshots --host "$SITE"
    ;;

  *) sed -n '25,31p' "$0"; exit 2 ;;
esac
