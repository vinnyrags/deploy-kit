#!/usr/bin/env bats
# provision/ssh-admin.sh — runs for real in the container (root): useradd, visudo, sshd -t.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$KIT/provision/ssh-admin.sh"
  export SSH_RELOAD=true ROOT_KEYS="$BATS_TEST_TMPDIR/root_keys"
  [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null
  mkdir -p /run/sshd
  ssh-keygen -q -t ed25519 -N '' -C key-one -f "$BATS_TEST_TMPDIR/one"
  ssh-keygen -q -t ed25519 -N '' -C key-two -f "$BATS_TEST_TMPDIR/two"
}
teardown() {
  userdel -r admintest 2>/dev/null || true
  rm -f /etc/sudoers.d/90-deploy-kit-admintest /etc/ssh/sshd_config.d/10-deploy-kit.conf /etc/ssh/sshd_config.d/99-broken.conf
}

@test "--user: key-only sudo user — key installed 600, NOPASSWD sudo works, not locked" {
  run bash "$S" --user admintest --key "$BATS_TEST_TMPDIR/one.pub"
  [ "$status" -eq 0 ]
  id -nG admintest | grep -qw sudo
  [ "$(stat -c '%a %U' /home/admintest/.ssh/authorized_keys)" = "600 admintest" ]
  [ "$(stat -c '%a' /home/admintest/.ssh)" = 700 ]
  [ "$(stat -c '%a' /etc/sudoers.d/90-deploy-kit-admintest)" = 440 ]
  [ "$(getent shadow admintest | cut -d: -f2)" = '*' ]   # '!' would refuse key logins
  sudo -u admintest sudo -n true
}

@test "--user twice: idempotent, and the key file replaces the old keys" {
  bash "$S" --user admintest --key "$BATS_TEST_TMPDIR/one.pub"
  run bash "$S" --user admintest --key "$BATS_TEST_TMPDIR/two.pub"
  [ "$status" -eq 0 ]
  [[ "$output" == *"user admintest exists"* ]]
  grep -q key-two /home/admintest/.ssh/authorized_keys
  ! grep -q key-one /home/admintest/.ssh/authorized_keys
}

@test "--user refuses a file with a non-key line, and creates nothing" {
  { cat "$BATS_TEST_TMPDIR/one.pub"; echo 'command=git-shell'; } > "$BATS_TEST_TMPDIR/bad.pub"
  run bash "$S" --user admintest --key "$BATS_TEST_TMPDIR/bad.pub"
  [ "$status" -ne 0 ]
  ! id admintest 2>/dev/null
}

@test "--no-x11: sshd reads X11Forwarding no from the drop-in" {
  run bash "$S" --no-x11
  [ "$status" -eq 0 ]
  sshd -T | grep -qx 'x11forwarding no'
}

@test "a config sshd -t rejects is rolled back" {
  echo 'NotARealKeyword yes' > /etc/ssh/sshd_config.d/99-broken.conf
  run bash "$S" --no-x11
  [ "$status" -ne 0 ]
  [[ "$output" == *"previous settings restored"* ]]
  [ ! -f /etc/ssh/sshd_config.d/10-deploy-kit.conf ]
}

@test "--lock-root refuses while no sudo user has a key" {
  run bash "$S" --lock-root
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing --lock-root"* ]]
  [ ! -f /etc/ssh/sshd_config.d/10-deploy-kit.conf ]
}

@test "--lock-root after --user: forced-commands-only, and names the root keys that stop working" {
  printf '%s\ncommand="git-shell -c \\"git-receive-pack x\\"",no-pty %s\n' \
    "$(cat "$BATS_TEST_TMPDIR/two.pub")" "$(cat "$BATS_TEST_TMPDIR/one.pub")" > "$ROOT_KEYS"
  bash "$S" --user admintest --key "$BATS_TEST_TMPDIR/one.pub"
  run bash "$S" --lock-root --no-x11
  [ "$status" -eq 0 ]
  [[ "$output" == *"stop working: key-two"* ]]
  [[ "$output" != *"stop working: key-two key-one"* ]]
  sshd -T | grep -qx 'permitrootlogin forced-commands-only'
  sshd -T | grep -qx 'x11forwarding no'
}
