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
  # wp: WP_FAIL = WordPress cannot load (WP-CLI prints an Error); WP_EMPTY = no tables yet.
  mkdir -p "$T/bin"; cat > "$T/bin/wp" <<'W'
#!/bin/sh
[ -n "$WP_FAIL" ] && { echo "Error: Error establishing a database connection." >&2; exit 1; }
[ -n "$WP_EMPTY" ] && case "$*" in *is-installed*) exit 1 ;; *) echo "Error: The site you have requested is not installed." >&2; exit 1 ;; esac
exit 0
W
  chmod +x "$T/bin/wp"
  export PATH="$T/bin:$PATH"
  # The real helpers (log, conf_map, pool_user, lock_secrets) and the real mythus-ix
  # profile_shared_paths; only the build, activation and smoke test are stubbed.
  source "$KIT/deploy/lib/common.sh"
  source "$KIT/deploy/profiles/mythus-ix.sh"
  profile_build() { [ -n "${BUILD_FAIL:-}" ] && return 1; mkdir -p "$1/vendor" "$1/theme/node_modules"; echo built > "$1/vendor/ok"; echo x > "$1/auth.json"; }
  profile_activate() { echo "activate $(basename "$(readlink -f "$2")")" >> "$CALLS"; }
  smoke_test() { echo "smoke as ${3:-}" >> "$CALLS"; [ -z "${SMOKE_FAIL:-}" ]; }
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

@test "a new site's first release switches before wp core install, if core is in the tree" {
  mkdir -p "$T/work/wp"; echo "<?php" > "$T/work/wp/wp-load.php"
  git -C "$T/work" add -A; git -C "$T/work" commit -qm core; git -C "$T/work" push -q origin HEAD:develop
  WP_EMPTY=1 run release_deploy develop "$BASE/current" staging "$(rev)"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -L "$BASE/current" ]
  [[ "$output" == *"WordPress not installed yet"* ]]
}

@test "an empty database does not excuse a release with no WordPress core" {
  WP_EMPTY=1 run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -ne 0 ]
  [ ! -e "$BASE/current" ]
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

@test "conf_map on an undeclared LAYOUT map is empty, not an error, under deploy.sh's set -euo pipefail" {
  # set -e matters: with only -u the aborted subshell didn't take the caller down,
  # so this passed while every conf without LAYOUT failed to deploy (2026-10-16).
  run bash -c 'set -euo pipefail; source "'"$KIT"'/deploy/lib/common.sh"; v="$(conf_map LAYOUT develop 2>/dev/null || true)"; echo "[$v]"'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "conf_map on any undeclared map is empty without a fallback (CACHE_DIR in the profiles)" {
  run bash -c 'set -euo pipefail; source "'"$KIT"'/deploy/lib/common.sh"; v="$(conf_map CACHE_DIR develop)"; echo "[$v]"'
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "SHARED_EXTRA links that branch's extra paths, and only that branch's" {
  mkdir -p "$BASE/shared/preview"; echo drop-in > "$BASE/shared/wp-content/object-cache.php"
  declare -A SHARED_EXTRA=( [main]="wp-content/object-cache.php preview" )
  git --git-dir="$BARE" branch -f main develop
  release_deploy main "$BASE/current" production "$(git --git-dir="$BARE" rev-parse main)"
  [ "$(readlink "$BASE/current/wp-content/object-cache.php")" = "$BASE/shared/wp-content/object-cache.php" ]
  [ "$(readlink "$BASE/current/preview")" = "$BASE/shared/preview" ]
  # develop has no SHARED_EXTRA entry: no drop-in, so it can never reach production's Redis.
  rm -rf "$BASE/releases" "$BASE/current"
  release_deploy develop "$BASE/current" staging "$(rev)"
  [ ! -e "$BASE/current/wp-content/object-cache.php" ]
  [ ! -e "$BASE/current/preview" ]
}

@test "a SHARED_EXTRA path missing from shared/ fails before anything is switched" {
  declare -A SHARED_EXTRA=( [develop]="wp-content/object-cache.php" )
  run release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared/wp-content/object-cache.php missing"* ]]
  [ ! -e "$BASE/current" ]
}

@test "shared secrets are locked to the pool user, and the smoke test runs as it" {
  id -u dktestpool >/dev/null 2>&1 || useradd --system --user-group --no-create-home dktestpool
  declare -A POOL_USER=( [develop]=dktestpool )
  release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$(stat -c '%U:%G %a' "$BASE/shared/wp-config-env.php")" = "root:dktestpool 640" ]
  grep -q "smoke as dktestpool" "$CALLS"
}

@test "without POOL_USER, secrets and the smoke test stay www-data (fleet default)" {
  release_deploy develop "$BASE/current" staging "$(rev)"
  [ "$(stat -c '%U:%G %a' "$BASE/shared/wp-config-env.php")" = "root:www-data 640" ]
  grep -q "smoke as www-data" "$CALLS"
}
