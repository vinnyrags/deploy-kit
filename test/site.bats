#!/usr/bin/env bats
# What new-site.sh builds (provision/lib/site.sh), and the pieces around it that a new
# site leans on: wp_state, the swap and firewall baseline, the per-site audit, the kit
# pin in setup-droplet.sh, and the key line onboard.sh installs. Root on Linux:
# `test/run.sh` (some tests write under /etc/nginx and /root, as on a droplet).

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  source "$KIT/deploy/lib/common.sh"
  source "$KIT/provision/lib/migrate.sh"
  source "$KIT/provision/lib/site.sh"
  id -u dksite >/dev/null 2>&1 || useradd --system --user-group --no-create-home dksite
}
teardown() { rm -rf "$T"; }

# --- site lib --------------------------------------------------------------------------
@test "pool users: the slug and <slug>-stg, an explicit base wins, never past 32 chars" {
  [ "$(site_pool_users example)" = "example example-stg" ]
  [ "$(site_pool_users example vinrag)" = "vinrag vinrag-stg" ]
  read -r p s <<<"$(site_pool_users threesummersoflincolnandsomemore)"
  [ "${#s}" -le 32 ]
  [ "$s" = "${p}-stg" ]
}

@test "site_init_base: releases/ and shared/ as root, writable paths owned by the pool user" {
  site_init_base "$T/srv/example.com" dksite
  [ "$(stat -c %U:%G "$T/srv/example.com/shared")" = root:root ]
  [ -d "$T/srv/example.com/releases" ]
  [ "$(stat -c %U "$T/srv/example.com/shared/wp-content/uploads")" = dksite ]
  [ "$(stat -c %U "$T/srv/example.com/shared/wp-content/debug.log")" = dksite ]
}

@test "site_init_base refuses a base that already exists" {
  mkdir -p "$T/srv/example.com"
  run site_init_base "$T/srv/example.com" dksite
  [ "$status" -ne 0 ]
  [[ "$output" == *REFUSING* ]]
}

@test "site_conf: releases + pool users on both branches, and deploy.sh accepts it" {
  site_conf example 8.4 /srv/example.com /srv/staging.example.com fastcgi-example example example-stg > "$T/c"
  ( set -euo pipefail; source "$T/c"
    [ "$(conf_map LAYOUT main)" = releases ] && [ "$(conf_map LAYOUT develop)" = releases ]
    [ "$(pool_user main)" = example ] && [ "$(pool_user develop)" = example-stg ]
    [ "$(conf_map DEPLOY_DIR main)" = /srv/example.com/current ]
    [ "$(conf_map CACHE_DIR develop)" = /var/cache/nginx/fastcgi-example-staging ]
    [ "$PROFILE" = mythus-ix ] && [ "$BACKUP_BRANCH" = main ] )
  source "$KIT/deploy/lib/releases.sh"
  ( source "$T/c"; [ "$(release_base "$(conf_map DEPLOY_DIR develop)")" = /srv/staging.example.com ] )
}

@test "site_vhost: rooted at <base>/current with \$realpath_root, and the env file is denied" {
  site_vhost "$KIT/nginx/vhost.conf.template" "example.com www.example.com" /srv/example.com 8.4 example EXAMPLE > "$T/v"
  grep -qE '^[[:space:]]*root /srv/example.com/current;' "$T/v"
  grep -q 'fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;' "$T/v"
  grep -q 'fastcgi_param DOCUMENT_ROOT $realpath_root;' "$T/v"
  ! grep -q '$document_root$fastcgi_script_name' "$T/v"
  grep -q 'fastcgi_cache EXAMPLE;' "$T/v"
  ! grep -q '{{' "$T/v"
}

@test "site_vhost output passes nginx -t with the kit's snippets and cache maps" {
  command -v nginx >/dev/null || skip "nginx not installed"
  mkdir -p /etc/nginx/snippets
  cp "$KIT/nginx/wp-hardening.snippet.conf" /etc/nginx/snippets/wp-hardening.conf
  cp "$KIT/nginx/scanner-block.snippet.conf" /etc/nginx/snippets/scanner-block.conf
  cp "$KIT/nginx/wp-microcache.snippet.conf" /etc/nginx/snippets/wp-microcache.conf
  sed -e 's#{{SITE}}#example#g' -e 's#{{ZONE}}#EXAMPLE#g' -e "s#/var/cache/nginx/{{ZONE_DIR}}#$T/cache#g" \
    "$KIT/nginx/wp-fastcgi-cache.conf.template" > "$T/cache.conf"
  site_vhost "$KIT/nginx/vhost.conf.template" example.com /srv/example.com 8.4 example EXAMPLE \
    | sed 's/listen 80;/listen 127.0.0.1:18082;/; /listen \[::\]:80;/d' > "$T/v"
  printf 'events {}\nhttp {\n include mime.types;\n fastcgi_cache_key "$scheme$request_method$host$request_uri";\n include %s;\n include %s;\n include %s;\n}\n' \
    "$KIT/nginx/wp-security.conf.template" "$T/cache.conf" "$T/v" > /etc/nginx/dk-site-test.conf
  run nginx -t -c /etc/nginx/dk-site-test.conf
  rm -f /etc/nginx/dk-site-test.conf
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[warn]"* ]]
}

@test "site_salts: eight distinct salts, and the rendered env file is valid PHP" {
  site_salts > "$T/s"
  [ "$(grep -c "^define( '" "$T/s")" -eq 8 ]
  [ "$(grep -oE "'[0-9a-f]{64}'" "$T/s" | sort -u | wc -l)" -eq 8 ]
  command -v php >/dev/null || skip "php cli not installed"
  { sed -e 's/{{WP_DEBUG}}/false/g' -e 's/{{[A-Z_]*}}/x/g' "$KIT/templates/wp-config-env.php.template"; cat "$T/s"; } > "$T/env.php"
  php -l "$T/env.php"
  run php -r 'require $argv[1]; echo AUTH_KEY === NONCE_SALT ? "same" : (DISABLE_WP_CRON ? "ok" : "cron");' "$T/env.php"
  [ "$output" = ok ]
}

# --- wp_state ------------------------------------------------------------------------------
wp_stub() { mkdir -p "$T/bin"; printf '#!/bin/sh\n%s\n' "$1" > "$T/bin/wp"; chmod +x "$T/bin/wp"; export PATH="$T/bin:$PATH"; }

@test "wp_state: exit 0 is installed; a silent exit 1 is an empty database" {
  wp_stub 'exit 0';  [ "$(wp_state /x)" = installed ]
  wp_stub 'exit 1';  [ "$(wp_state /x)" = not-installed ]
}

@test "wp_state: a WP-CLI Error or a PHP fatal is an error, a mere warning is not" {
  wp_stub 'echo "Error: Error establishing a database connection." >&2; exit 1'
  [ "$(wp_state /x)" = error ]
  wp_stub 'echo "PHP Fatal error:  Uncaught Error: Failed opening required" >&2; exit 1'
  [ "$(wp_state /x)" = error ]
  wp_stub 'echo "PHP Deprecated: something in a plugin" >&2; exit 1'
  [ "$(wp_state /x)" = not-installed ]
}

@test "wp_state runs as the given user" {
  wp_stub '[ "$(id -un)" = dksite ] || { echo "Error: wrong user" >&2; exit 1; }; exit 0'
  chmod 755 "$T" "$T/bin"
  [ "$(wp_state /x dksite)" = installed ]
}

# --- swap + firewall baseline ---------------------------------------------------------------
@test "apply_swap: a swapfile when there is none, fstab and swappiness once" {
  source "$KIT/provision/lib/baseline.sh"
  mkdir -p "$T/bin"; : > "$T/calls"
  for c in fallocate mkswap swapon sysctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n[ "%s" = fallocate ] && : > "$3"\nexit 0\n' "$c" "$T/calls" "$c" > "$T/bin/$c"
  done
  chmod +x "$T/bin"/*; export PATH="$T/bin:$PATH"
  : > "$T/fstab"
  SWAPFILE="$T/swapfile" FSTAB="$T/fstab" SYSCTL_FILE="$T/sysctl" run apply_swap 2G
  [[ "$output" == *"swapfile"* ]]
  grep -q "fallocate -l 2G $T/swapfile" "$T/calls"
  [ "$(grep -c swapfile "$T/fstab")" -eq 1 ]
  [ "$(cat "$T/sysctl")" = "vm.swappiness = 10" ]
  SWAPFILE="$T/swapfile" FSTAB="$T/fstab" SYSCTL_FILE="$T/sysctl" run apply_swap 2G
  [ "$(grep -c swapfile "$T/fstab")" -eq 1 ]
}

@test "apply_swap leaves existing swap alone" {
  source "$KIT/provision/lib/baseline.sh"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\necho "/swapfile file 2G 0B -2"\n' > "$T/bin/swapon"
  printf '#!/bin/sh\necho "fallocate $*" >> "%s"\n' "$T/calls" > "$T/bin/fallocate"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/sysctl"
  chmod +x "$T/bin"/*; export PATH="$T/bin:$PATH"
  : > "$T/fstab"
  SWAPFILE="$T/none" FSTAB="$T/fstab" SYSCTL_FILE="$T/sysctl" run apply_swap 2G
  [[ "$output" == *"swap present"* ]]
  [ ! -e "$T/calls" ]
}

@test "apply_firewall keeps a Cloudflare-only lock: no allow-from-anywhere web rule" {
  source "$KIT/provision/lib/baseline.sh"
  mkdir -p "$T/bin"; : > "$T/calls"
  cat > "$T/bin/ufw" <<S
#!/bin/sh
echo "ufw \$*" >> "$T/calls"
case "\$1" in
  status) printf 'Status: active\n\nTo Action From\n22/tcp ALLOW Anywhere\n443/tcp ALLOW 173.245.48.0/20\n' ;;
  app) echo "  Nginx Full" ;;
esac
S
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/systemctl"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/fail2ban-client"
  chmod +x "$T/bin"/*; export PATH="$T/bin:$PATH"
  run apply_firewall
  [ "$status" -eq 0 ]
  [[ "$output" == *"web rules present, left alone"* ]]
  ! grep -q "ufw allow Nginx Full" "$T/calls"
  ! grep -q "ufw allow 80,443/tcp" "$T/calls"
  grep -qx "ufw allow OpenSSH" "$T/calls"
}

# --- per-site audit ------------------------------------------------------------------------
@test "audit_sites: production without a backup timer FAILs; cron and layout WARN" {
  source "$KIT/provision/lib/audit.sh"
  run audit_sites "" <<<"newsite main mythus-ix inplace"
  [[ "$output" == *$'FAIL\tsite.backup'* ]]
  [[ "$output" == *$'WARN\tsite.cron'* ]]
  [[ "$output" == *$'WARN\tsite.layout'* ]]
}

@test "audit_sites: a site with everything passes; staging-only and nextjs need no backup" {
  source "$KIT/provision/lib/audit.sh"
  timers=$'deploy-kit-backup@vr.timer\ndeploy-kit-wpcron@vr:main.timer\ndeploy-kit-wpcron@vr:develop.timer'
  run audit_sites "$timers" <<<$'vr main mythus-ix releases\nvr develop mythus-ix releases\ndemo develop mythus-ix releases\napp main nextjs releases'
  [[ "$output" != *FAIL* ]]
  [ "$(grep -c $'PASS\tsite.backup' <<<"$output")" -eq 1 ]
  [ "$(grep -c $'PASS\tsite.cron' <<<"$output")" -eq 2 ]
  [[ "$output" == *$'WARN\tsite.cron\tdemo [develop]'* ]]
  [[ "$output" != *"app"* ]]
}

# --- setup-droplet: one kit per box, so never re-pin by default ------------------------------
kit_fixture() {
  git init -q "$T/kit"; git -C "$T/kit" config user.email t@t; git -C "$T/kit" config user.name t
  mkdir -p "$T/kit/deploy/hooks"; cp "$KIT/deploy/hooks/post-receive" "$T/kit/deploy/hooks/"
  git -C "$T/kit" add -A; git -C "$T/kit" commit -qm one; git -C "$T/kit" tag v1.0.0
  echo 2 > "$T/kit/x"; git -C "$T/kit" add -A; git -C "$T/kit" commit -qm two; git -C "$T/kit" tag v1.1.0
  git -C "$T/kit" remote add origin "$T/kit"
  git -C "$T/kit" checkout -q v1.0.0
  mkdir -p /var/repo; rm -rf /var/repo/dk-site-test.git; git init -q --bare /var/repo/dk-site-test.git
  echo "PROFILE=mythus-ix" > "$T/conf"
}

@test "setup-droplet without a ref leaves the box's kit where it is pinned" {
  kit_fixture
  DEPLOY_KIT_DIR="$T/kit" run bash "$KIT/provision/setup-droplet.sh" dk-site-test "$T/conf"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/kit" describe --tags)" = v1.0.0 ]
  grep -q "SITE_CONF=\"$T/conf\"" /var/repo/dk-site-test.git/hooks/post-receive
}

@test "setup-droplet with a ref moves the pin" {
  kit_fixture
  DEPLOY_KIT_DIR="$T/kit" run bash "$KIT/provision/setup-droplet.sh" dk-site-test "$T/conf" v1.1.0
  [ "$status" -eq 0 ]
  [ "$(git -C "$T/kit" describe --tags)" = v1.1.0 ]
}

# --- onboard.sh: the key line, through sudo, once ----------------------------------------------
@test "onboard installs one forced-command line in root's keys via the ssh target's sudo" {
  mkdir -p "$T/bin" "$T/repo" /root/.ssh; touch /root/.ssh/authorized_keys
  echo "ssh-ed25519 AAAAexisting other-key" >> /root/.ssh/authorized_keys
  cp /root/.ssh/authorized_keys "$T/keys.bak"
  # ssh <opts> <target> <remote command>: run the remote command here, as the remote shell would.
  cat > "$T/bin/ssh" <<'S'
#!/bin/sh
echo "$@" | grep -q 'admin@box' || { echo "wrong target: $*" >&2; exit 1; }
for a; do last="$a"; done
sh -c "$last"
S
  printf '#!/bin/sh\nshift; exec "$@"\n' > "$T/bin/sudo"               # sudo -n <cmd…>
  # Drain stdin only when the secret comes from it: an unread pipe can SIGPIPE the writer.
  printf '#!/bin/sh\necho "gh $*" >> "%s"\ncase "$*" in *--body*) ;; *) cat >/dev/null ;; esac\n' "$T/gh" > "$T/bin/gh"
  printf '#!/bin/sh\necho "203.0.113.10 ssh-ed25519 AAAAhostkey"\n' > "$T/bin/ssh-keyscan"
  chmod +x "$T/bin"/*
  PATH="$T/bin:$PATH" run bash "$KIT/bin/onboard.sh" "$T/repo" org/demo 203.0.113.10 demo admin@box
  echo "$output"
  [ "$status" -eq 0 ]
  first="$(grep 'deploy-demo-ci' /root/.ssh/authorized_keys)"
  PATH="$T/bin:$PATH" bash "$KIT/bin/onboard.sh" "$T/repo" org/demo 203.0.113.10 demo admin@box >/dev/null
  line="$(grep 'deploy-demo-ci' /root/.ssh/authorized_keys)"
  others="$(grep -vc 'deploy-demo-ci' /root/.ssh/authorized_keys || true)"
  mode="$(stat -c %a /root/.ssh/authorized_keys)"
  cp "$T/keys.bak" /root/.ssh/authorized_keys
  [ "$(printf '%s\n' "$line" | wc -l)" -eq 1 ]      # a re-run replaces, never appends
  [ "$line" != "$first" ]                             # …with the key now in the GitHub secret
  [ "$others" -eq "$(grep -c . "$T/keys.bak" || true)" ]
  [ "$mode" = 600 ]
  [[ "$line" == 'command="git-shell -c \"git-receive-pack '"'"'/var/repo/demo.git'"'"'\"",no-port-forwarding,no-agent-forwarding,no-pty ssh-ed25519 '* ]]
  grep -q "needs: audit" "$T/repo/.github/workflows/deploy.yml"
  grep -q "gh secret set DROPLET_HOST --repo org/demo --body 203.0.113.10" "$T/gh"
}

# --- verify-site.sh: where to look, from the conf ------------------------------------------
@test "verify-site checks a releases site at <base>/current as its pool user; no conf falls back" {
  cat > "$T/c" <<'C'
declare -A DEPLOY_DIR=( [main]=/srv/example.com/current [develop]=/srv/staging.example.com/current )
declare -A POOL_USER=( [main]=example [develop]=example-stg )
C
  { echo "SITE_CONF=$T/c"
    sed -n '/^conf_get()/,/^}/p;/^run_env()/,/^}/p' "$KIT/provision/verify-site.sh"
    echo 'check_env() { echo "$1 $2 $3 $WP_USER"; }'
    echo 'run_env main example.com production; run_env develop staging.example.com staging'
    echo 'SITE_CONF=/nonexistent; run_env main legacy.com production'; } > "$T/t.sh"
  run bash "$T/t.sh"
  echo "$output"
  [ "${lines[0]}" = "example.com /srv/example.com/current production example" ]
  [ "${lines[1]}" = "staging.example.com /srv/staging.example.com/current staging example-stg" ]
  [ "${lines[2]}" = "legacy.com /var/www/legacy.com/public production www-data" ]
}
