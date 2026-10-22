#!/bin/bash
# deploy-kit — a hardened systemd unit for a self-hosted Next.js app. As root.
#
#     nextjs-service.sh <unit> --user <name> --dir <app dir> --port <port> [--start]
#     e.g. nextjs-service.sh itzenzo-tv --user itzenzo --dir /var/www/itzenzo.tv --port 3001
#
# Creates the no-login system user (home /var/lib/<user>, for npm's cache) if missing and
# writes /etc/systemd/system/<unit>.service: the app runs as that user, may write only
# <dir>/.next (ISR and image cache), and sees a read-only system and no /home. One process —
# a cluster buys nothing on a 1-vCPU box. Idempotent; `systemd-analyze verify` must pass,
# or the previous unit is restored. --start enables and (re)starts it; without it the
# unit is installed and enabled only, so a PM2 process on the same port isn't fought.
set -euo pipefail

UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
NODE_BIN="${NODE_BIN:-/usr/bin/node}"

UNIT="${1:?unit name}"; shift; UNIT="${UNIT%.service}"
USER_=""; DIR=""; PORT=""; START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_="${2:?}"; shift ;; --dir) DIR="${2:?}"; shift ;; --port) PORT="${2:?}"; shift ;;
    --start) START=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$USER_" ] && [ -n "$DIR" ] && [ -n "$PORT" ] || { sed -n '4,5p' "$0"; exit 2; }
case "$PORT" in *[!0-9]*) echo "--port must be a number" >&2; exit 2 ;; esac
[ "$USER_" != root ] || { echo "refusing to run a Next.js app as root" >&2; exit 1; }

log() { echo ">> $*"; }

if ! id "$USER_" >/dev/null 2>&1; then
  useradd --system --home-dir "/var/lib/$USER_" --create-home --shell /usr/sbin/nologin "$USER_"
  log "user $USER_ created (home /var/lib/$USER_)"
fi

f="$UNIT_DIR/$UNIT.service"
tmp="$(mktemp)"
cat > "$tmp" <<UNITFILE
# deploy-kit nextjs-service.sh — do not edit by hand; re-run the script.
[Unit]
Description=Next.js app $UNIT ($DIR, port $PORT)
After=network.target

[Service]
Type=simple
User=$USER_
Group=$USER_
WorkingDirectory=$DIR
Environment=NODE_ENV=production PORT=$PORT
ExecStart=$NODE_BIN $DIR/node_modules/next/dist/bin/next start -p $PORT
Restart=on-failure
RestartSec=5

NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=$DIR/.next
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
UNITFILE

[ -f "$f" ] && cp -a "$f" "$f.bak"
install -m 644 "$tmp" "$f"; rm -f "$tmp"
if command -v systemd-analyze >/dev/null && ! out="$(systemd-analyze verify "$f" 2>&1)"; then
  if [ -f "$f.bak" ]; then mv "$f.bak" "$f"; else rm -f "$f"; fi
  echo "systemd-analyze verify FAILED — previous unit restored:" >&2; echo "$out" >&2; exit 1
fi
rm -f "$f.bak"
log "unit $f"

$SYSTEMCTL daemon-reload
$SYSTEMCTL enable "$UNIT.service" >/dev/null 2>&1
if [ "$START" = 1 ]; then
  $SYSTEMCTL restart "$UNIT.service"
  log "started $UNIT.service"
else
  log "enabled, not started (pass --start once the port is free)"
fi
