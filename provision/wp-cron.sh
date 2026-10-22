#!/bin/bash
# deploy-kit — run WP-Cron from a system timer instead of page traffic.
#
# WordPress fires due cron events from inside an uncached PHP request. Behind a page
# cache most anonymous requests never reach PHP, so scheduled work (Yoast, Smash
# Balloon, transient cleanup, scheduled posts) runs late and unevenly — and when it
# does run, it runs inside some visitor's request. This runs it every minute instead,
# as the branch's pool user — POOL_USER[branch], else www-data — so files it writes are
# owned like the site's own, and it can read the env file that only that pool can.
#
#   Usage:
#     wp-cron.sh --install <site.conf> [branch...]   install + start a timer per branch
#     wp-cron.sh --run     <site.conf> <branch>      run due events once (the timer runs this)
#
#   Order: --install first, confirm `systemctl list-timers` shows it, THEN set
#     define('DISABLE_WP_CRON', true);
#   in that environment's wp-config-env.php. The other order leaves a window with no
#   cron at all. Undo: remove the define first, then disable the timer.

set -euo pipefail

MODE="${1:-}"; CONF="${2:-}"
KIT="${DEPLOY_KIT_DIR:-/opt/deploy-kit}"
[ -n "$MODE" ] && [ -r "$CONF" ] || { sed -n '10,17p' "$0"; exit 2; }

# shellcheck disable=SC1090
source "$CONF"
# shellcheck disable=SC1091
source "$KIT/deploy/lib/common.sh"
SITE="$(basename "$CONF" .conf)"

case "$MODE" in
  --install)
    shift 2
    branches=("$@"); [ ${#branches[@]} -gt 0 ] || branches=(main)
    install -m 0644 "$KIT/provision/systemd/deploy-kit-wpcron@.service" /etc/systemd/system/
    install -m 0644 "$KIT/provision/systemd/deploy-kit-wpcron@.timer"   /etc/systemd/system/
    systemctl daemon-reload
    for b in "${branches[@]}"; do
      [ -n "$(conf_map DEPLOY_DIR "$b")" ] || { echo "no DEPLOY_DIR[$b] in $CONF" >&2; exit 1; }
      systemctl enable --now "deploy-kit-wpcron@${SITE}:${b}.timer"
    done
    systemctl list-timers 'deploy-kit-wpcron@*' --no-pager
    ;;
  --run)
    BRANCH="${3:?branch required}"
    DEST="$(conf_map DEPLOY_DIR "$BRANCH")"
    [ -n "$DEST" ] || { echo "no DEPLOY_DIR[$BRANCH] in $CONF" >&2; exit 1; }
    # new-site.sh starts the timer before the first deploy and `wp core install`: until
    # then there is nothing to run, and a failing unit every minute would be noise.
    [ -f "$DEST/wp/wp-load.php" ] || exit 0
    [ "$(wp_state "$DEST/wp" "$(pool_user "$BRANCH")")" = not-installed ] && exit 0
    exec runuser -u "$(pool_user "$BRANCH")" -- wp --path="$DEST/wp" cron event run --due-now --quiet
    ;;
  *) sed -n '10,17p' "$0"; exit 2 ;;
esac
