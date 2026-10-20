#!/usr/bin/env bats
# provision/lib/pools.sh + provision/lib/vhost.sh, and the scanner-block snippet.
# `test/run.sh` runs this in an Ubuntu container with nginx and php-fpm installed, so
# the rendered artifacts are validated by the real binaries, not just grepped.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  source "$KIT/provision/lib/pools.sh"
  source "$KIT/provision/lib/vhost.sh"
  cat > "$T/vhost" <<'V'
server {
    server_name example.com;
    include snippets/wp-hardening.conf;

    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
    }
}
server {
    server_name www.example.com;
    include snippets/wp-hardening.conf;
    return 301 https://example.com$request_uri;
}
V
}
teardown() { rm -rf "$T"; }

@test "prod pool: own socket, dynamic, max_children honoured, slow log" {
  run render_pool example 8.4 prod 8
  [ "$status" -eq 0 ]
  [[ "$output" == *"[example]"* ]]
  [[ "$output" == *"listen = /run/php/php8.4-fpm-example.sock"* ]]
  [[ "$output" == *"pm = dynamic"* ]]
  [[ "$output" == *"pm.max_children = 8"* ]]
  [[ "$output" == *"request_slowlog_timeout = 2s"* ]]
  [[ "$output" == *"slowlog = /var/log/php8.4-fpm-example.slow.log"* ]]
}

@test "prod pool defaults to 6 workers; staging is ondemand with 2" {
  run render_pool example 8.4 prod;           [[ "$output" == *"pm.max_children = 6"* ]]
  run render_pool example-staging 8.4 staging
  [[ "$output" == *"pm = ondemand"* ]]
  [[ "$output" == *"pm.max_children = 2"* ]]
  [[ "$output" == *"pm.process_idle_timeout = 30s"* ]]
}

@test "rewire points fastcgi_pass at the pool socket and reports the count" {
  run rewire_vhost_socket "$T/vhost" 8.4 example
  [ "$output" = 1 ]
  grep -q 'fastcgi_pass unix:/run/php/php8.4-fpm-example.sock;' "$T/vhost"
  ! grep -q 'php8.4-fpm.sock' "$T/vhost"
}

@test "rewire is idempotent and moves a vhost between pools" {
  rewire_vhost_socket "$T/vhost" 8.4 example >/dev/null
  run rewire_vhost_socket "$T/vhost" 8.4 example-staging
  [ "$output" = 1 ]
  grep -q 'php8.4-fpm-example-staging.sock;' "$T/vhost"
}

@test "rewire leaves another PHP version's socket alone" {
  sed -i 's/8.4/8.3/' "$T/vhost"
  run rewire_vhost_socket "$T/vhost" 8.4 example
  [ "$output" = 0 ]
  grep -q 'php8.3-fpm.sock' "$T/vhost"
}

@test "scanner include lands right after every wp-hardening include, same indent" {
  run add_include_after_hardening "$T/vhost" scanner-block
  [ "$output" = added ]
  [ "$(grep -c 'include snippets/scanner-block.conf;' "$T/vhost")" -eq 2 ]
  grep -A1 'wp-hardening.conf;' "$T/vhost" | grep -q '^    include snippets/scanner-block.conf;'
  # before the PHP location: first-match regex ordering
  [ "$(grep -n scanner-block "$T/vhost" | head -1 | cut -d: -f1)" -lt "$(grep -n 'location ~' "$T/vhost" | cut -d: -f1)" ]
}

@test "scanner include is idempotent, and refuses a vhost with no hardening anchor" {
  add_include_after_hardening "$T/vhost" scanner-block >/dev/null
  run add_include_after_hardening "$T/vhost" scanner-block
  [ "$output" = present ]
  [ "$(grep -c scanner-block "$T/vhost")" -eq 2 ]
  printf 'server {\n  listen 80;\n}\n' > "$T/bare"
  run add_include_after_hardening "$T/bare" scanner-block
  [ "$output" = no-anchor ]
  ! grep -q scanner-block "$T/bare"
}

@test "scanner-block snippet passes nginx -t inside a WordPress server block" {
  command -v nginx >/dev/null || skip "nginx not installed"
  mkdir -p "$T/n/snippets"
  cp "$KIT/nginx/scanner-block.snippet.conf" "$T/n/snippets/scanner-block.conf"
  cat > "$T/n/nginx.conf" <<N
events {}
http {
  server {
    listen 127.0.0.1:18080;
    root /tmp;
    include $T/n/snippets/scanner-block.conf;
    location = /robots.txt { try_files \$uri /index.php?\$args; }
    location / { try_files \$uri \$uri/ /index.php?\$args; }
  }
}
N
  run nginx -t -c "$T/n/nginx.conf" -p "$T/n"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[warn]"* ]]
}

@test "rendered pools pass php-fpm -t" {
  fpm="$(ls /usr/sbin/php-fpm* 2>/dev/null | head -1)"
  [ -n "$fpm" ] || skip "php-fpm not installed"
  mkdir -p "$T/fpm/pool.d"
  render_pool example 8.4 prod     > "$T/fpm/pool.d/example.conf"
  render_pool example-stg 8.4 staging > "$T/fpm/pool.d/example-stg.conf"
  printf '[global]\nerror_log = %s/fpm.log\ninclude=%s/fpm/pool.d/*.conf\n' "$T" "$T" > "$T/fpm/php-fpm.conf"
  run "$fpm" -t -y "$T/fpm/php-fpm.conf"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "pool user: user and group follow it, the socket stays nginx's" {
  run render_pool example 8.4 prod 8 vinrag
  [[ "$output" == *"user = vinrag"* ]]
  [[ "$output" == *"group = vinrag"* ]]
  [[ "$output" == *"listen.owner = www-data"* ]]
  [[ "$output" == *"listen.group = www-data"* ]]
}

@test "pool user defaults to www-data, so existing pools render unchanged" {
  run render_pool example 8.4 prod
  [[ "$output" == *"user = www-data"* ]]
  [[ "$output" == *"group = www-data"* ]]
}

@test "a pool with its own user passes php-fpm -t" {
  fpm="$(ls /usr/sbin/php-fpm* 2>/dev/null | head -1)"
  [ -n "$fpm" ] || skip "php-fpm not installed"
  id -u dkpool >/dev/null 2>&1 || useradd --system --user-group --no-create-home dkpool
  mkdir -p "$T/fpm/pool.d"
  render_pool example 8.4 prod 4 dkpool > "$T/fpm/pool.d/example.conf"
  printf '[global]\nerror_log = %s/fpm.log\ninclude=%s/fpm/pool.d/*.conf\n' "$T" "$T" > "$T/fpm/php-fpm.conf"
  run "$fpm" -t -y "$T/fpm/php-fpm.conf"
  echo "$output"
  [ "$status" -eq 0 ]
}
