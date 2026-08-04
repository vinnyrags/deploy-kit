#!/bin/bash
# deploy-kit — run ON a droplet to install/update the kit and wire one bare repo's
# post-receive hook to it. Idempotent. Backs up any existing hook.
#
# Usage:  setup-droplet.sh <bare_repo_name> <site_conf_path> [kit_ref]
#   bare_repo_name   e.g. aviewfromthebridge   (-> /var/repo/aviewfromthebridge.git)
#   site_conf_path   e.g. /etc/deploy-kit/aviewfromthebridge.conf  (write this first)
#   kit_ref          tag/branch to pin (default: v1)
set -euo pipefail

BARE_NAME="${1:?bare repo name}"
SITE_CONF="${2:?site conf path}"
KIT_REF="${3:-v1}"
KIT_DIR="${DEPLOY_KIT_DIR:-/opt/deploy-kit}"
REPO_URL="https://github.com/vinnyrags/deploy-kit.git"
HOOK="/var/repo/${BARE_NAME}.git/hooks/post-receive"

[ -f "$SITE_CONF" ] || { echo "site conf not found: $SITE_CONF (write it first)"; exit 1; }
[ -d "/var/repo/${BARE_NAME}.git" ] || { echo "bare repo not found: /var/repo/${BARE_NAME}.git"; exit 1; }

# 1) kit present + pinned
if [ ! -d "$KIT_DIR/.git" ]; then
  echo ">> cloning deploy-kit -> $KIT_DIR"
  git clone --quiet "$REPO_URL" "$KIT_DIR"
fi
git -C "$KIT_DIR" fetch --tags --quiet origin
git -C "$KIT_DIR" checkout --quiet "$KIT_REF"
echo ">> deploy-kit pinned at $KIT_REF ($(git -C "$KIT_DIR" rev-parse --short HEAD))"

# 2) wire the hook (back up existing)
if [ -f "$HOOK" ] && ! grep -q "deploy-kit post-receive stub" "$HOOK"; then
  cp "$HOOK" "${HOOK}.bak.$(date +%Y%m%d%H%M%S)"
  echo ">> backed up existing hook -> ${HOOK}.bak.*"
fi
sed "s#__SITE_CONF__#${SITE_CONF}#" "$KIT_DIR/deploy/hooks/post-receive" > "$HOOK"
chmod +x "$HOOK"
echo ">> wired $HOOK  (conf: $SITE_CONF, kit: $KIT_REF)"
