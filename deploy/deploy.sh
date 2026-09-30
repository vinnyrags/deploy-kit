#!/bin/bash
# deploy-kit — deploy dispatcher. Runs ON the droplet, invoked by the post-receive
# hook stub. Sources the per-site config (which names a PROFILE), then hands off to
# that profile's deploy routine. Stack-agnostic core; all stack knowledge lives in
# the profile + the config.
#
# Usage (from post-receive):  deploy.sh <branch> <site.conf> [newrev] [oldrev]
set -euo pipefail

# The machine-readable outcome, printed last. git IGNORES a post-receive hook's
# exit status — the push is accepted before the hook runs — so a failed build or
# smoke test still left `git push`, and therefore CI, green. The v2 workflow reads
# this line instead and fails unless it says `ok` or `skipped`.
RESULT=">> DEPLOY-KIT-RESULT:"
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "$RESULT fail (exit $rc)"' EXIT

BRANCH="${1:?branch required}"
CONF="${2:?site conf required}"
NEWREV="${3:-}"

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The bare repo git dir — provided by the post-receive hook via GIT_DIR.
BARE="$(cd "${GIT_DIR:-$PWD}" && pwd)"
export BARE

# Node comes from nvm, which is not on a non-login shell's PATH. The post-receive
# hook sources it, but deploy.sh is also run by hand to replay a deploy during
# recovery — and without this that run dies at the npm build with a bare
# "npm: command not found", after composer has already changed the tree.
# Harmless when the hook has already loaded it.
if [ -s "${NVM_DIR:-/root/.nvm}/nvm.sh" ] && ! command -v npm >/dev/null 2>&1; then
  export NVM_DIR="${NVM_DIR:-/root/.nvm}"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
fi

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
  echo "$RESULT skipped"
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
echo "$RESULT ok"
