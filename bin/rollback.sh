#!/bin/bash
# deploy-kit — point a LAYOUT=releases environment back at its previous release.
# Runs ON the droplet. One atomic symlink switch, then php-fpm reload + cache purge.
#
#   Usage:  rollback.sh /etc/deploy-kit/<site>.conf <branch>
#
# Rolling back code does not roll back the database. A release that ran a migration
# needs that migration undone by hand.
set -euo pipefail
CONF="${1:?site conf required}"; BRANCH="${2:?branch required}"
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$KIT/deploy/lib/common.sh"
# shellcheck disable=SC1091
source "$KIT/deploy/lib/releases.sh"
# shellcheck disable=SC1090
source "$CONF"
# shellcheck disable=SC1090
source "$KIT/deploy/profiles/${PROFILE:?}.sh"
[ "$(conf_map LAYOUT "$BRANCH" 2>/dev/null || true)" = releases ] || { echo "$BRANCH is not LAYOUT=releases" >&2; exit 1; }
release_rollback "$BRANCH" "$(conf_map DEPLOY_DIR "$BRANCH")"
