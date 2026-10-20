#!/bin/bash
# deploy-kit — move one branch of a mythus-ix site from an in-place docroot to
# LAYOUT=releases (atomic, read-only releases with auto-rollback). As root, ON the droplet.
#
#   migrate-to-releases.sh --prepare  --site <name> --branch <b> --conf <new.conf> --from <docroot> --bare <repo.git> --vhost <name>
#   migrate-to-releases.sh --switch   (same arguments)
#   migrate-to-releases.sh --rollback (same arguments)
#
#   <new.conf>  the site conf AFTER the move: DEPLOY_DIR[b]=<base>/current, LAYOUT[b]=releases,
#               POOL_USER[b], and SHARED_EXTRA[b] for anything else PHP or the site needs
#               from the old docroot (a Redis drop-in, hand-placed files). It is installed as
#               /etc/deploy-kit/<name>.conf only by --switch.
#
# --prepare changes nothing the site serves: it creates <base>/shared/ from real copies of
#   the live docroot's state, builds the first release with <new.conf> (nginx still serves
#   the old docroot, so that deploy's own smoke test proves only that the build finished),
#   and checks the release: shared links, WordPress loading as the pool user.
# --switch is the one live moment: final rsync of uploads and shared dirs, the vhost moved
#   to <base>/current with $realpath_root (nginx -t must be warning-free), the conf
#   installed, caches purged, then a live smoke test — which ROLLS BACK on its own if it
#   fails, the same rule release deploys follow.
# --rollback restores the vhost and conf --switch backed up. The old docroot is left
#   untouched throughout, as the fallback; uploads made after the switch need rsyncing back.
set -euo pipefail

KIT="${KIT:-/opt/deploy-kit}"
# shellcheck disable=SC1091
source "$KIT/deploy/lib/common.sh"
# shellcheck disable=SC1091
source "$KIT/provision/lib/migrate.sh"

MODE="${1:-}"; shift || true
SITE=""; BRANCH=""; NEWCONF=""; OLD=""; BARE_REPO=""; VHOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --site) SITE="${2:?}"; shift ;; --branch) BRANCH="${2:?}"; shift ;;
    --conf) NEWCONF="${2:?}"; shift ;; --from) OLD="${2:?}"; shift ;;
    --bare) BARE_REPO="${2:?}"; shift ;; --vhost) VHOST="${2:?}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
for v in SITE BRANCH NEWCONF OLD BARE_REPO VHOST; do [ -n "${!v}" ] || { sed -n '5,8p' "$0"; exit 2; }; done
case "$MODE" in --prepare|--switch|--rollback) ;; *) sed -n '5,8p' "$0"; exit 2 ;; esac

# The target conf decides where everything goes.
# shellcheck disable=SC1090
source "$NEWCONF"
DEST="$(conf_map DEPLOY_DIR "$BRANCH")"
[ "$(conf_map LAYOUT "$BRANCH")" = releases ] || { echo "$NEWCONF: LAYOUT[$BRANCH] must be releases" >&2; exit 1; }
case "$DEST" in */current) ;; *) echo "$NEWCONF: DEPLOY_DIR[$BRANCH] must end in /current" >&2; exit 1 ;; esac
BASE="$(dirname "$DEST")"
USER_="$(pool_user "$BRANCH")"
# shellcheck disable=SC2207
EXTRA=($(conf_map SHARED_EXTRA "$BRANCH"))
LIVE_CONF="/etc/deploy-kit/${SITE}.conf"
STATE="/root/migrate-bak/${SITE}-${BRANCH}"
VHOST_FILE="$(readlink -f "/etc/nginx/sites-enabled/${VHOST}")"
[ -f "$VHOST_FILE" ] || { echo "no enabled vhost $VHOST" >&2; exit 1; }
[ -d "$OLD" ] || { echo "no old docroot $OLD" >&2; exit 1; }

restore_switch() {
  log "restoring vhost and conf from $STATE"
  cp -a "$STATE/vhost" "$VHOST_FILE"
  cp -a "$STATE/site.conf" "$LIVE_CONF"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx
  flush_fastcgi "$(conf_map CACHE_DIR "$BRANCH")"
}

case "$MODE" in
  --prepare)
    grep -qE "^[[:space:]]*root[[:space:]]+${DEST//\//\\/};" "$VHOST_FILE" && { echo "$VHOST already serves $DEST — nothing to prepare" >&2; exit 1; }
    log "shared state: $OLD -> $BASE/shared (copies, owner $USER_)"
    mapfile -t PATHS < <(shared_paths_for "${EXTRA[@]}")
    copy_shared "$OLD" "$BASE" "$USER_" "${PATHS[@]}"
    log "first release, built with $NEWCONF (nginx still serves $OLD)"
    ( cd "$BARE_REPO" && GIT_DIR="$PWD" bash "$KIT/deploy/deploy.sh" "$BRANCH" "$NEWCONF" "$(git rev-parse "$BRANCH")" ) \
      | grep -E '^>> (release|switched|smoke|ROLLED|pruned)|DEPLOY-KIT-RESULT'
    [ -L "$DEST" ] || { echo "no $DEST after the build" >&2; exit 1; }
    log "checking the release before nginx sees it"
    for p in "${PATHS[@]}"; do
      [ "$(readlink "$DEST/$p")" = "$BASE/shared/$p" ] && echo "   link ok  $p" || { echo "   NOT LINKED: $p" >&2; exit 1; }
    done
    ( cd "$DEST" && sudo -u "$USER_" wp --path=wp core is-installed ) && echo "   WordPress loads as $USER_"
    log "PREPARED. Nothing the site serves has changed. Next: $0 --switch (same arguments)"
    ;;

  --switch)
    [ -L "$DEST" ] || { echo "not prepared: no $DEST" >&2; exit 1; }
    log "final sync of uploads and shared directories"
    rsync -a "$OLD/wp-content/uploads/" "$BASE/shared/wp-content/uploads/"
    for p in "${EXTRA[@]}"; do [ -d "$OLD/$p" ] && rsync -a "$OLD/$p/" "$BASE/shared/$p/"; done
    chown -R "${USER_}:${USER_}" "$BASE/shared/wp-content/uploads"
    mkdir -p "$STATE"; cp -a "$VHOST_FILE" "$STATE/vhost"; cp -a "$LIVE_CONF" "$STATE/site.conf"
    log "backups -> $STATE"
    log "vhost: $(vhost_to_releases "$VHOST_FILE" "$OLD" "$DEST")"
    out="$(nginx -t 2>&1)" || { restore_switch; echo "nginx -t FAILED — restored:" >&2; echo "$out" >&2; exit 1; }
    printf '%s' "$out" | grep -q '\[warn\]' && { restore_switch; echo "nginx -t WARNED — restored:" >&2; echo "$out" >&2; exit 1; }
    install -m 0644 "$NEWCONF" "$LIVE_CONF"
    systemctl reload nginx
    flush_fastcgi "$(conf_map CACHE_DIR "$BRANCH")"
    wp --path="$DEST/wp" --allow-root cache flush --quiet 2>/dev/null || true
    if smoke_test "$DEST" "$(conf_map ENV_NAME "$BRANCH")" "$USER_"; then
      log "SWITCHED: $VHOST serves $DEST. Old docroot $OLD left as the fallback."
    else
      restore_switch
      echo "live smoke test FAILED — switched back to $OLD" >&2; exit 1
    fi
    ;;

  --rollback)
    [ -f "$STATE/vhost" ] || { echo "no switch backups in $STATE" >&2; exit 1; }
    restore_switch
    log "ROLLED BACK: $VHOST serves $OLD again. Uploads made since the switch are in $BASE/shared."
    ;;
esac
