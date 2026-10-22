#!/bin/bash
# deploy-kit — run ON a droplet to install the kit and wire one bare repo's
# post-receive hook to it. Idempotent. Backs up any existing hook.
#
# Usage:  setup-droplet.sh <bare_repo_name> <site_conf_path> [kit_ref]
#   bare_repo_name   e.g. aviewfromthebridge   (-> /var/repo/aviewfromthebridge.git)
#   site_conf_path   e.g. /etc/deploy-kit/aviewfromthebridge.conf  (write this first)
#   kit_ref          tag to pin. Omitted: the kit stays at the ref it is pinned to, or is
#                    cloned at the latest release tag if it is not installed yet. It is
#                    one checkout for the whole droplet, so a ref given here moves every
#                    site on the box — roll it deliberately.
set -euo pipefail

BARE_NAME="${1:?bare repo name}"
SITE_CONF="${2:?site conf path}"
KIT_REF="${3:-}"
KIT_DIR="${DEPLOY_KIT_DIR:-/opt/deploy-kit}"
REPO_URL="https://github.com/vinnyrags/deploy-kit.git"
HOOK="/var/repo/${BARE_NAME}.git/hooks/post-receive"

[ -f "$SITE_CONF" ] || { echo "site conf not found: $SITE_CONF (write it first)"; exit 1; }
[ -d "/var/repo/${BARE_NAME}.git" ] || { echo "bare repo not found: /var/repo/${BARE_NAME}.git"; exit 1; }

# 1) kit present + pinned
if [ ! -d "$KIT_DIR/.git" ]; then
  echo ">> cloning deploy-kit -> $KIT_DIR"
  git clone --quiet "$REPO_URL" "$KIT_DIR"
  [ -n "$KIT_REF" ] || KIT_REF="$(git -C "$KIT_DIR" tag --sort=-v:refname | grep -m1 -E '^v[0-9]+\.[0-9]+\.[0-9]+$')"
fi
if [ -n "$KIT_REF" ]; then
  git -C "$KIT_DIR" fetch --tags --quiet origin
  git -C "$KIT_DIR" checkout --quiet "$KIT_REF"
fi
echo ">> deploy-kit at $(git -C "$KIT_DIR" describe --tags --always) ($(git -C "$KIT_DIR" rev-parse --short HEAD))"

# 2) wire the hook (back up existing)
if [ -f "$HOOK" ] && ! grep -q "deploy-kit post-receive stub" "$HOOK"; then
  cp "$HOOK" "${HOOK}.bak.$(date +%Y%m%d%H%M%S)"
  echo ">> backed up existing hook -> ${HOOK}.bak.*"
fi
sed "s#__SITE_CONF__#${SITE_CONF}#" "$KIT_DIR/deploy/hooks/post-receive" > "$HOOK"
chmod +x "$HOOK"
echo ">> wired $HOOK  (conf: $SITE_CONF)"
