#!/bin/bash
# deploy-kit — system Node.js from NodeSource's signed apt repo, patched by unattended-upgrades.
# As root.
#
#     node.sh [--major 24] [--no-install]
#
# Writes the repo (signed-by its own keyring), an apt pin so NodeSource's nodejs wins over
# Ubuntu's older one, and /etc/apt/apt.conf.d/53deploy-kit-nodesource, which lets
# unattended-upgrades install Node patches like the PHP PPA's (52unattended-local belongs to
# baseline.sh, so this lives in its own file). Then installs nodejs unless --no-install.
# One system Node in /usr/bin, readable by any app user — not an nvm copy in /root.
# Idempotent. Changing --major moves the box to that line on the next install.
set -euo pipefail

MAJOR=24; INSTALL=1
while [ $# -gt 0 ]; do
  case "$1" in --major) MAJOR="${2:?}"; shift ;; --no-install) INSTALL=0 ;; *) echo "unknown arg: $1" >&2; exit 2 ;; esac
  shift
done
case "$MAJOR" in *[!0-9]*|'') echo "--major must be a number" >&2; exit 2 ;; esac

ROOT="${NODE_ROOT:-}"   # tests write under a fake root
KEYRING="$ROOT/usr/share/keyrings/nodesource.gpg"
LIST="$ROOT/etc/apt/sources.list.d/nodesource.list"
PIN="$ROOT/etc/apt/preferences.d/nodesource"
UU="$ROOT/etc/apt/apt.conf.d/53deploy-kit-nodesource"
KEY_URL="https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key"
log() { echo ">> $*"; }

mkdir -p "$(dirname "$KEYRING")" "$(dirname "$LIST")" "$(dirname "$PIN")" "$(dirname "$UU")"
if [ ! -s "$KEYRING" ]; then
  if [ -n "${NODE_KEY_FILE:-}" ]; then gpg --dearmor < "$NODE_KEY_FILE" > "$KEYRING"
  else curl -fsSL "$KEY_URL" | gpg --dearmor > "$KEYRING"; fi
  chmod 644 "$KEYRING"
  log "keyring $KEYRING"
fi

echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${MAJOR}.x nodistro main" > "$LIST"
printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' > "$PIN"
cat > "$UU" <<'CONF'
// deploy-kit node.sh — Node.js patches from NodeSource install unattended, like the PHP PPA's.
Unattended-Upgrade::Origins-Pattern {
        "site=deb.nodesource.com";
};
CONF
log "repo node_${MAJOR}.x, pin 600, unattended-upgrades origin site=deb.nodesource.com"

if [ "$INSTALL" = 1 ]; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  have="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$have" = "$MAJOR" ] || { echo "installed node is v$have, expected v$MAJOR" >&2; exit 1; }
  log "node $(node -v) at $(command -v node)"
fi
