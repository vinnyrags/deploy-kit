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

@test "smoke_test: a fatal in the theme fails the deploy, even though it breaks reading home" {
  # wp: installed; `option get home` works only with --skip-themes (the theme fatals).
  mkdir -p "$T/bin" "$T/site/wp"; touch "$T/site/wp/wp-load.php"; chmod 755 "$T" "$T/bin"
  cat > "$T/bin/wp" <<'W'
#!/bin/sh
case "$*" in
  *is-installed*) exit 0 ;;
  *"option get home"*--skip-themes*) echo https://example.com ;;
  *"option get home"*) echo "PHP Fatal error: Uncaught Error: Call to undefined function" >&2; exit 255 ;;
esac
W
  printf '#!/bin/sh\nwhile [ "$1" = -u ]; do shift 2; done\nexec "$@"\n' > "$T/bin/sudo"
  printf '#!/bin/sh\necho "${CURL_CODE:-500}"\n' > "$T/bin/curl"
  chmod +x "$T/bin"/*; export PATH="$T/bin:$PATH"
  run smoke_test "$T/site" staging dkcommon
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SMOKE TEST FAILED: example.com returned 500"* ]]
  CURL_CODE=200 run smoke_test "$T/site" staging dkcommon
  [ "$status" -eq 0 ]
}
