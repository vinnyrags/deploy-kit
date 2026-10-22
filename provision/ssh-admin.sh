#!/bin/bash
# deploy-kit — a sudo user for humans, and the SSH settings that go with it. As root.
#
#     ssh-admin.sh --user <name> --key <public key file>   # add or refresh the admin user
#     ssh-admin.sh --no-x11                                # X11Forwarding no
#     ssh-admin.sh --lock-root                             # PermitRootLogin forced-commands-only
#
# Flags combine; each is opt-in and idempotent. The admin user logs in by key only (no
# password, not locked) and has NOPASSWD sudo, so Makefile targets keep working as
# `ssh <host> sudo …`. Its authorized_keys is replaced by --key on every run: the file you
# pass is the source of truth.
#
# --lock-root leaves root reachable ONLY through keys with a forced command (the CI deploy
# keys). Any other root key stops working, so it refuses unless a sudo user already has a
# key, and lists the root keys that will stop working. Prove `ssh <user>@host sudo true`
# from a second terminal before running it.
#
# SSH settings go in /etc/ssh/sshd_config.d/10-deploy-kit.conf. sshd keeps the FIRST value it
# reads, and Ubuntu includes sshd_config.d/* before its own lines, so 10- wins over the
# distro and cloud-init files. `sshd -t` must pass, or the previous file is restored.
set -euo pipefail

SSHD_DROPIN="${SSHD_DROPIN:-/etc/ssh/sshd_config.d/10-deploy-kit.conf}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
SSH_RELOAD="${SSH_RELOAD:-systemctl reload ssh}"
ROOT_KEYS="${ROOT_KEYS:-/root/.ssh/authorized_keys}"

USER_=""; KEY=""; NO_X11=0; LOCK_ROOT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_="${2:?}"; shift ;; --key) KEY="${2:?}"; shift ;;
    --no-x11) NO_X11=1 ;; --lock-root) LOCK_ROOT=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ -z "$USER_" ] && [ -z "$KEY" ] && [ "$NO_X11" = 0 ] && [ "$LOCK_ROOT" = 0 ]; then sed -n '4,6p' "$0"; exit 2; fi
if { [ -n "$USER_" ] || [ -n "$KEY" ]; } && { [ -z "$USER_" ] || [ -z "$KEY" ]; }; then
  echo "--user and --key go together" >&2; exit 2
fi

log() { echo ">> $*"; }

# A sudo-group user with a non-empty authorized_keys and a sudoers rule — someone who can
# still get in once root can't.
admin_users() {
  local u home
  for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [ -s "$home/.ssh/authorized_keys" ] && grep -qs "^$u " "$SUDOERS_DIR"/* && echo "$u"
  done
  return 0
}

add_admin() {
  local u="$1" key="$2" home tmp
  [ -r "$key" ] || { echo "cannot read $key" >&2; exit 1; }
  # every non-blank line must be a public key: a stray line would install nothing usable
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s\n' "$line" | ssh-keygen -lf - >/dev/null 2>&1 || { echo "not a public key: ${line:0:40}…" >&2; exit 1; }
  done < "$key"
  grep -q . "$key" || { echo "$key has no keys" >&2; exit 1; }

  if id "$u" >/dev/null 2>&1; then log "user $u exists"
  else useradd --create-home --shell /bin/bash "$u"; log "user $u created"; fi
  usermod -aG sudo "$u"
  usermod -p '*' "$u"   # no password, but not locked ('!'), so key login is allowed
  home="$(getent passwd "$u" | cut -d: -f6)"
  install -d -m 700 -o "$u" -g "$u" "$home/.ssh"
  install -m 600 -o "$u" -g "$u" "$key" "$home/.ssh/authorized_keys"
  log "$home/.ssh/authorized_keys: $(grep -c . "$key") key(s)"

  tmp="$(mktemp)"
  printf '# deploy-kit ssh-admin.sh — key-only login, so no password to type\n%s ALL=(ALL) NOPASSWD:ALL\n' "$u" > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; echo "sudoers rule failed visudo" >&2; exit 1; }
  install -m 440 -o root -g root "$tmp" "$SUDOERS_DIR/90-deploy-kit-$u"; rm -f "$tmp"
  log "sudo: NOPASSWD via $SUDOERS_DIR/90-deploy-kit-$u"
}

set_sshd() {  # set_sshd <Keyword> <value> — one line per keyword; builds on any pending change
  local base="$SSHD_DROPIN" tmp; tmp="$(mktemp)"
  [ -f "$SSHD_DROPIN.new" ] && base="$SSHD_DROPIN.new"
  if [ -f "$base" ]; then grep -vi "^$1 " "$base" > "$tmp" || true
  else echo '# deploy-kit ssh-admin.sh — sshd keeps the first value, so this file sorts first' > "$tmp"; fi
  echo "$1 $2" >> "$tmp"
  install -m 644 "$tmp" "$SSHD_DROPIN.new"; rm -f "$tmp"
}

apply_sshd() {
  [ -f "$SSHD_DROPIN.new" ] || return 0
  [ -f "$SSHD_DROPIN" ] && cp -a "$SSHD_DROPIN" "$SSHD_DROPIN.bak"
  mv "$SSHD_DROPIN.new" "$SSHD_DROPIN"
  if ! sshd -t; then
    if [ -f "$SSHD_DROPIN.bak" ]; then mv "$SSHD_DROPIN.bak" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    echo "sshd -t FAILED — previous settings restored" >&2; exit 1
  fi
  rm -f "$SSHD_DROPIN.bak"
  $SSH_RELOAD
  log "sshd: $(sshd -T 2>/dev/null | grep -E '^(x11forwarding|permitrootlogin) ' | tr '\n' ' ')"
}

[ -n "$USER_" ] && add_admin "$USER_" "$KEY"
[ "$NO_X11" = 1 ] && set_sshd X11Forwarding no
if [ "$LOCK_ROOT" = 1 ]; then
  admins="$(admin_users)"
  [ -n "$admins" ] || { echo "refusing --lock-root: no sudo user with an SSH key — add one with --user first" >&2; exit 1; }
  log "admin user(s) with a key: $admins"
  if [ -f "$ROOT_KEYS" ]; then
    lost="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT_KEYS" | grep -v '^command=' | sed -E 's/.* //' || true)"
    [ -n "$lost" ] && log "root keys without a forced command — these stop working: $(echo "$lost" | tr '\n' ' ')"
  fi
  set_sshd PermitRootLogin forced-commands-only
fi
apply_sshd
