#!/usr/bin/env bats
# deploy/lib/common.sh — pool_user and lock_secrets. Root on Linux: `test/run.sh`.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  source "$KIT/deploy/lib/common.sh"
  id -u dkcommon >/dev/null 2>&1 || useradd --system --user-group --no-create-home dkcommon
}
teardown() { rm -rf "$T"; }

@test "pool_user reads POOL_USER[branch]" {
  declare -A POOL_USER=( [main]=vinrag [develop]=vinrag-stg )
  [ "$(pool_user main)" = vinrag ]
  [ "$(pool_user develop)" = vinrag-stg ]
}

@test "pool_user falls back to www-data: no map, or no entry for the branch" {
  [ "$(pool_user main)" = www-data ]
  declare -A POOL_USER=( [main]=vinrag )
  [ "$(pool_user develop)" = www-data ]
}

@test "lock_secrets: 640 root:<group> on env and auth files, default group www-data" {
  echo x > "$T/wp-config-env.php"; echo y > "$T/auth.json"; chmod 666 "$T/wp-config-env.php"
  lock_secrets "$T" dkcommon
  [ "$(stat -c '%U:%G %a' "$T/wp-config-env.php")" = "root:dkcommon 640" ]
  [ "$(stat -c '%U:%G %a' "$T/auth.json")" = "root:dkcommon 640" ]
  lock_secrets "$T"
  [ "$(stat -c '%U:%G' "$T/wp-config-env.php")" = "root:www-data" ]
}

@test "lock_secrets succeeds when neither file exists" {
  run lock_secrets "$T" dkcommon
  [ "$status" -eq 0 ]
}
