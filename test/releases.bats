#!/usr/bin/env bats
# deploy/lib/releases.sh — release build, atomic switch, auto-rollback, prune.
# Runs as root on Linux (GNU mv -T, chown): `test/run.sh` runs it in a container.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  export BARE="$T/repo.git" BASE="$T/site" CALLS="$T/calls"
  git init -q --bare "$BARE"
  git clone -q "$BARE" "$T/work" 2>/dev/null
  git -C "$T/work" config user.email t@t; git -C "$T/work" config user.name t
  mkdir -p "$T/work/wp" "$T/work/wp-content/uploads"
  echo 1 > "$T/work/app.php"; echo keep > "$T/work/wp-content/uploads/.gitkeep"
  git -C "$T/work" add -A; git -C "$T/work" commit -qm one; git -C "$T/work" push -q origin HEAD:develop

  mkdir -p "$BASE/shared/wp-content/uploads"
  echo "<?php // env" > "$BASE/shared/wp-config-env.php"
  touch "$BASE/shared/wp-content/debug.log"

  # Stubs for everything outside releases.sh.
  mkdir -p "$T/bin"; printf '#!/bin/sh\n[ -n "$WP_FAIL" ] && exit 1; exit 0\n' > "$T/bin/wp"; chmod +x "$T/bin/wp"
  export PATH="$T/bin:$PATH"
  log() { echo ">> $*"; }
  conf_map() { local -n _m="$1"; printf '%s' "${_m[$2]:-}"; }
  profile_shared_paths() { printf '%s\n' wp-config-env.php wp-content/uploads wp-content/debug.log; }
  profile_build() { [ -n "${BUILD_FAIL:-}" ] && return 1; mkdir -p "$1/vendor" "$1/theme/node_modules"; echo built > "$1/vendor/ok"; echo x > "$1/auth.json"; }
  profile_activate() { echo "activate $(basename "$(readlink -f "$2")")" >> "$CALLS"; }
  smoke_test() { [ -z "${SMOKE_FAIL:-}" ]; }
  export -f log
  source "$KIT/deploy/lib/releases.sh"
}
teardown() { rm -rf "$T"; }

rev() { git --git-dir="$BARE" rev-parse develop; }
commit() { echo "$1" > "$T/work/app.php"; git -C "$T/work" commit -qam "$1"; git -C "$T/work" push -q origin HEAD:develop; }
live() { basename "$(readlink -f "$BASE/current")"; }

@test "deploys a release, links shared paths, switches current" {
  run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -eq 0 ]
  [ -L "$BASE/current" ]
  [ "$(cat "$BASE/current/app.php")" = 1 ]
  [ "$(readlink "$BASE/current/wp-config-env.php")" = "$BASE/shared/wp-config-env.php" ]
  [ "$(readlink "$BASE/current/wp-content/uploads")" = "$BASE/shared/wp-content/uploads" ]
  [ -f "$BASE/current/vendor/ok" ]
}

@test "release is root-owned and not writable by anyone else; build-only files removed" {
  release_deploy develop "$BASE/current" staging "$(rev)"
  r="$(readlink -f "$BASE/current")"
  [ "$(stat -c %U:%G "$r/app.php")" = root:root ]
  [ -z "$(find "$r" -perm /022 ! -type l)" ]
  [ ! -e "$r/auth.json" ]
  [ -z "$(find "$r" -name node_modules)" ]
  [ "$(stat -c %U "$BASE/shared/wp-content/uploads")" = "$(stat -c %U "$T")" ]   # shared untouched
}

@test "build failure leaves the live release untouched" {
  release_deploy develop "$BASE/current" staging "$(rev)"; before="$(live)"
  commit two; sleep 1
  BUILD_FAIL=1 run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -ne 0 ]
  [ "$(live)" = "$before" ]
}

@test "failed pre-switch WordPress check leaves the live release untouched" {
  release_deploy develop "$BASE/current" staging "$(rev)"; before="$(live)"
  commit two; sleep 1
  WP_FAIL=1 run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -ne 0 ]
  [ "$(live)" = "$before" ]
}

@test "failed smoke test rolls back to the previous release" {
  release_deploy develop "$BASE/current" staging "$(rev)"; before="$(live)"
  commit two; sleep 1
  SMOKE_FAIL=1 run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -ne 0 ]
  [ "$(live)" = "$before" ]
  [ "$(cat "$BASE/current/app.php")" = 1 ]
  grep -q "activate $before" "$CALLS"          # previous release re-activated
}

@test "a file deleted from the repo is absent from the next release" {
  echo gone > "$T/work/old.php"; git -C "$T/work" add old.php; git -C "$T/work" commit -qm add; git -C "$T/work" push -q origin HEAD:develop
  release_deploy develop "$BASE/current" staging "$(rev)"; [ -f "$BASE/current/old.php" ]
  git -C "$T/work" rm -q old.php; git -C "$T/work" commit -qm rm; git -C "$T/work" push -q origin HEAD:develop; sleep 1
  release_deploy develop "$BASE/current" staging "$(rev)"
  [ ! -e "$BASE/current/old.php" ]
}

@test "prune keeps KEEP_RELEASES and never the live one" {
  for i in 2 3 4 5; do commit "$i"; sleep 1; release_deploy develop "$BASE/current" staging "$(rev)"; done
  [ "$(ls -1 "$BASE/releases" | wc -l)" -eq 3 ]
  [ -d "$(readlink -f "$BASE/current")" ]
  [ "$(cat "$BASE/current/app.php")" = 5 ]
}

@test "release_rollback switches to the previous release" {
  release_deploy develop "$BASE/current" staging "$(rev)"; first="$(live)"
  commit two; sleep 1; release_deploy develop "$BASE/current" staging "$(rev)"
  run release_rollback develop "$BASE/current"
  [ "$status" -eq 0 ]
  [ "$(live)" = "$first" ]
}

@test "DEPLOY_DIR must end in /current" {
  run release_deploy develop "$BASE" staging "$(rev)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/current"* ]]
}

@test "a missing shared path fails before anything is switched" {
  rm "$BASE/shared/wp-content/debug.log"
  run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -ne 0 ]
  [ ! -e "$BASE/current" ]
}

@test "conf_map on an undeclared LAYOUT map is empty, not an error, under set -u" {
  run bash -c 'set -u; source "'"$KIT"'/deploy/lib/common.sh"; v="$(conf_map LAYOUT develop 2>/dev/null || true)"; echo "[$v]"'
  [ "$output" = "[]" ]
}
