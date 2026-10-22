#!/usr/bin/env bats
# deploy/profiles/nextjs.sh, provision/nextjs-service.sh, provision/node.sh.
# Real useradd/runuser/systemd-analyze; npm, systemctl and curl are stubs.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"; chmod 755 "$T"
  export BARE="$T/repo.git" CALLS="$T/calls" DEST="$T/app"
  git init -q --bare "$BARE"
  git clone -q "$BARE" "$T/work" 2>/dev/null
  git -C "$T/work" config user.email t@t; git -C "$T/work" config user.name t
  echo '{}' > "$T/work/package.json"; mkdir -p "$T/work/scripts"
  printf '#!/bin/bash\necho "warm $(whoami) $1" >> "%s"\n[ -z "$WARM_FAIL" ]\n' "$CALLS" > "$T/work/scripts/warm.sh"
  git -C "$T/work" add -A; git -C "$T/work" commit -qm one; git -C "$T/work" push -q origin HEAD:main

  mkdir -p "$T/bin"
  printf '#!/bin/bash\necho "npm $1 $(whoami)" >> "%s"\n[ "$1" = run ] && { [ -n "$BUILD_FAIL" ] && exit 1; mkdir -p .next; echo x > .next/BUILD_ID; }\nexit 0\n' "$CALLS" > "$T/bin/npm"
  printf '#!/bin/sh\necho "systemctl $*" >> "%s"\n' "$CALLS" > "$T/bin/systemctl"
  printf '#!/bin/sh\nprintf "%%s" "${SMOKE_CODE:-200}"\n' > "$T/bin/curl"
  chmod 755 "$T/bin"/*; touch "$CALLS"; chmod 666 "$CALLS"
  export PATH="$T/bin:$PATH" SMOKE_WAIT=0 SMOKE_TRIES=2

  id apptest >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin apptest
  source "$KIT/deploy/lib/common.sh"
  source "$KIT/deploy/profiles/nextjs.sh"
  declare -gA APP_USER=( [main]=apptest ) SYSTEMD_UNIT=( [main]=app.service ) PORT=( [main]=3001 ) \
    POST_DEPLOY=( [main]=scripts/warm.sh ) SITE_URL=( [main]=https://app.example )
}
teardown() { rm -rf "$T" /etc/systemd/system/svctest.service; userdel svcuser 2>/dev/null || true; rm -rf /var/lib/svcuser; }

@test "builds as APP_USER, locks .env to 640 root:user, restarts the unit, smoke + warm-up run" {
  mkdir -p "$DEST"; echo SECRET=1 > "$DEST/.env.production"
  run profile_deploy main "$DEST" production
  [ "$status" -eq 0 ]
  grep -qx 'npm ci apptest' "$CALLS"
  grep -qx 'npm run apptest' "$CALLS"
  [ "$(stat -c '%a %U:%G' "$DEST/.env.production")" = "640 root:apptest" ]
  [ "$(cat "$DEST/.env.production")" = SECRET=1 ]           # kept across the checkout
  grep -qx 'systemctl restart app.service' "$CALLS"
  [[ "$output" == *"smoke: 127.0.0.1:3001 -> 200 OK"* ]]
  grep -qx 'warm apptest https://app.example' "$CALLS"
}

@test "a failed smoke test fails the deploy, and says it is not a rollback" {
  SMOKE_CODE=502 run profile_deploy main "$DEST" production
  [ "$status" -ne 0 ]
  [[ "$output" == *"SMOKE TEST FAILED: 127.0.0.1:3001 returned 502"* ]]
  ! grep -q '^warm' "$CALLS"
}

@test "a failed build fails before the unit is restarted" {
  BUILD_FAIL=1 run profile_deploy main "$DEST" production
  [ "$status" -ne 0 ]
  ! grep -q 'systemctl restart' "$CALLS"
}

@test "a failing warm-up only warns" {
  WARM_FAIL=1 run profile_deploy main "$DEST" production
  [ "$status" -eq 0 ]
  [[ "$output" == *"post-deploy failed (warning only)"* ]]
}

@test "without APP_USER the build runs as root, as before" {
  unset APP_USER
  run profile_deploy main "$DEST" production
  [ "$status" -eq 0 ]
  grep -qx 'npm ci root' "$CALLS"
}

@test "nextjs-service: creates a no-login user and a unit systemd-analyze accepts" {
  mkdir -p "$DEST/.next"
  run env SYSTEMCTL=systemctl NODE_BIN=/bin/true bash "$KIT/provision/nextjs-service.sh" svctest --user svcuser --dir "$DEST" --port 3009
  [ "$status" -eq 0 ]
  [ "$(getent passwd svcuser | cut -d: -f6,7)" = "/var/lib/svcuser:/usr/sbin/nologin" ]
  f=/etc/systemd/system/svctest.service
  grep -qx 'User=svcuser' "$f"
  grep -qx 'ProtectSystem=strict' "$f"
  grep -qx "ReadWritePaths=$DEST/.next" "$f"
  grep -qx "ExecStart=/bin/true $DEST/node_modules/next/dist/bin/next start -p 3009" "$f"
  [[ "$output" == *"installed, not enabled or started"* ]]
  ! grep -q 'enable' "$CALLS"   # an enabled unit would start on reboot and fight PM2 for the port
}

@test "nextjs-service --start enables and starts" {
  mkdir -p "$DEST/.next"
  run env SYSTEMCTL=systemctl NODE_BIN=/bin/true bash "$KIT/provision/nextjs-service.sh" svctest --user svcuser --dir "$DEST" --port 3009 --start
  [ "$status" -eq 0 ]
  grep -qx 'systemctl enable svctest.service' "$CALLS"
  grep -qx 'systemctl restart svctest.service' "$CALLS"
}

@test "nextjs-service refuses root and a non-numeric port" {
  run env SYSTEMCTL=true bash "$KIT/provision/nextjs-service.sh" svctest --user root --dir "$DEST" --port 3009
  [ "$status" -ne 0 ]; [[ "$output" == *"refusing to run a Next.js app as root"* ]]
  run env SYSTEMCTL=true bash "$KIT/provision/nextjs-service.sh" svctest --user svcuser --dir "$DEST" --port abc
  [ "$status" -ne 0 ]
  [ ! -f /etc/systemd/system/svctest.service ]
}

@test "node.sh --no-install: signed repo for the major, pin 600, unattended-upgrades origin" {
  export GNUPGHOME="$T/gnupg"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --passphrase '' --quick-gen-key test@example.com default default never 2>/dev/null
  gpg --armor --export test@example.com > "$T/key.asc"
  run env NODE_ROOT="$T/root" NODE_KEY_FILE="$T/key.asc" bash "$KIT/provision/node.sh" --major 24 --no-install
  [ "$status" -eq 0 ]
  [ -s "$T/root/usr/share/keyrings/nodesource.gpg" ]
  grep -q 'signed-by=/usr/share/keyrings/nodesource.gpg\] https://deb.nodesource.com/node_24.x nodistro main' "$T/root/etc/apt/sources.list.d/nodesource.list"
  grep -qx 'Pin-Priority: 600' "$T/root/etc/apt/preferences.d/nodesource"
  grep -q '"site=deb.nodesource.com";' "$T/root/etc/apt/apt.conf.d/53deploy-kit-nodesource"
  run bash "$KIT/provision/node.sh" --major abc --no-install
  [ "$status" -ne 0 ]
}

# --- LAYOUT=releases for nextjs ---------------------------------------------------------
rel_setup() {
  source "$KIT/deploy/lib/releases.sh"
  export BASE="$T/site"; mkdir -p "$BASE/shared"; echo SECRET=1 > "$BASE/shared/.env.production"
  mkdir -p "$T/work/node_stub"; echo x > "$T/work/node_stub/keep"
}
rel_rev() { git --git-dir="$BARE" rev-parse main; }
rel_live() { basename "$(readlink -f "$BASE/current")"; }

@test "releases: builds as APP_USER, keeps node_modules, code root-owned with a writable .next, switches + restarts" {
  rel_setup
  printf '#!/bin/bash\necho "npm $1 $(whoami)" >> "%s"\n[ "$1" = ci ] && mkdir -p node_modules/next && echo m > node_modules/next/x\n[ "$1" = run ] && { [ -n "$BUILD_FAIL" ] && exit 1; [ -n "$NO_BUILD_ID" ] || { mkdir -p .next; echo id > .next/BUILD_ID; }; }\nexit 0\n' "$CALLS" > "$T/bin/npm"
  run release_deploy main "$BASE/current" production "$(rel_rev)"
  [ "$status" -eq 0 ]
  grep -qx 'npm run apptest' "$CALLS"
  [ "$(readlink "$BASE/current/.env.production")" = "$BASE/shared/.env.production" ]
  [ "$(stat -c '%a %U:%G' "$BASE/shared/.env.production")" = "640 root:apptest" ]
  [ -f "$BASE/current/node_modules/next/x" ]                              # next start needs it
  [ "$(stat -c '%U' "$BASE/current/package.json")" = root ]
  [ "$(stat -c '%U' "$BASE/current/.next/BUILD_ID")" = apptest ]          # ISR + image cache
  grep -qx 'systemctl restart app.service' "$CALLS"
  grep -qx 'warm apptest https://app.example' "$CALLS"
}

@test "releases: a failed smoke test switches back to the previous release" {
  rel_setup
  printf '#!/bin/bash\n[ "$1" = run ] && { mkdir -p .next; echo id > .next/BUILD_ID; }\nexit 0\n' > "$T/bin/npm"
  release_deploy main "$BASE/current" production "$(rel_rev)" >/dev/null
  first="$(rel_live)"
  echo two > "$T/work/two"; git -C "$T/work" add -A; git -C "$T/work" commit -qm two; git -C "$T/work" push -q origin HEAD:main
  sleep 1
  SMOKE_CODE=502 run release_deploy main "$BASE/current" production "$(rel_rev)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ROLLED BACK"* ]]
  [ "$(rel_live)" = "$first" ]
}

@test "releases: a failed build or a missing BUILD_ID never switches" {
  rel_setup
  printf '#!/bin/bash\n[ "$1" = run ] && { [ -n "$BUILD_FAIL" ] && exit 1; [ -n "$NO_BUILD_ID" ] || { mkdir -p .next; echo id > .next/BUILD_ID; }; }\nexit 0\n' > "$T/bin/npm"
  BUILD_FAIL=1 run release_deploy main "$BASE/current" production "$(rel_rev)"
  [ "$status" -ne 0 ]; [ ! -e "$BASE/current" ]
  NO_BUILD_ID=1 run release_deploy main "$BASE/current" production "$(rel_rev)"
  [ "$status" -ne 0 ]; [[ "$output" == *"no .next/BUILD_ID"* ]]; [ ! -e "$BASE/current" ]
  ! grep -q 'systemctl restart' "$CALLS"
}
