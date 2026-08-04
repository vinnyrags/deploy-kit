#!/bin/bash
# deploy-kit — deploy dispatcher. Runs ON the droplet, invoked by the post-receive
# hook stub. Sources the per-site config (which names a PROFILE), then hands off to
# that profile's deploy routine. Stack-agnostic core; all stack knowledge lives in
# the profile + the config.
#
# Usage (from post-receive):  deploy.sh <branch> <site.conf> [newrev] [oldrev]
set -euo pipefail

BRANCH="${1:?branch required}"
CONF="${2:?site conf required}"
NEWREV="${3:-}"

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The bare repo git dir — provided by the post-receive hook via GIT_DIR.
BARE="$(cd "${GIT_DIR:-$PWD}" && pwd)"
export BARE

# shellcheck disable=SC1090
source "$KIT/deploy/lib/common.sh"
# shellcheck disable=SC1090
source "$CONF"                                   # -> PROFILE, DEPLOY_DIR[], etc.
: "${PROFILE:?site conf must set PROFILE}"
# shellcheck disable=SC1090
source "$KIT/deploy/profiles/${PROFILE}.sh"      # -> profile_deploy()

DEST="$(conf_map DEPLOY_DIR "$BRANCH")"
if [ -z "$DEST" ]; then
  log "$BRANCH: no deploy target in $(basename "$CONF"), skipping"
  exit 0
fi
ENV_NAME="$(conf_map ENV_NAME "$BRANCH")"; ENV_NAME="${ENV_NAME:-$BRANCH}"

echo "============================================"
log "Deploying $BRANCH -> $ENV_NAME  ($DEST)  @ ${NEWREV:0:8}"
echo "============================================"

profile_deploy "$BRANCH" "$DEST" "$ENV_NAME"

echo "============================================"
log "Deployed $BRANCH -> $ENV_NAME"
echo "============================================"
