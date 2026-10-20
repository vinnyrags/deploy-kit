#!/usr/bin/env bats
# provision/lib/migrate.sh — the vhost rewrite and the shared-state copy behind
# migrate-to-releases.sh. Root on Linux: `test/run.sh`.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  source "$KIT/provision/lib/migrate.sh"
  cat > "$T/vhost" <<'V'
server {
    server_name example.com;
    root /var/www/example.com;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param QUERY_STRING $query_string;
    }
}
V
}
teardown() { rm -rf "$T"; }

@test "vhost_to_releases moves root and sets \$realpath_root params after include fastcgi_params" {
  run vhost_to_releases "$T/vhost" /var/www/example.com /srv/example.com/current
  [ "$output" = rewritten ]
  grep -q '^    root /srv/example.com/current;$' "$T/vhost"
  ! grep -q 'document_root\$fastcgi_script_name' "$T/vhost"
  inc="$(grep -n 'include fastcgi_params;' "$T/vhost" | cut -d: -f1)"
  sf="$(grep -n 'SCRIPT_FILENAME \$realpath_root' "$T/vhost" | cut -d: -f1)"
  dr="$(grep -n 'DOCUMENT_ROOT \$realpath_root' "$T/vhost" | cut -d: -f1)"
  [ "$sf" -gt "$inc" ] && [ "$dr" -gt "$inc" ]          # after the include: PHP-FPM keeps the LAST value
  grep -q 'fastcgi_param QUERY_STRING' "$T/vhost"         # unrelated params untouched
}

@test "vhost_to_releases is idempotent and refuses a vhost without the expected root" {
  vhost_to_releases "$T/vhost" /var/www/example.com /srv/example.com/current >/dev/null
  cp "$T/vhost" "$T/once"
  run vhost_to_releases "$T/vhost" /var/www/example.com /srv/example.com/current
  [ "$output" = already ]
  cmp -s "$T/once" "$T/vhost"
  printf 'server { root /elsewhere; }\n' > "$T/other"
  run vhost_to_releases "$T/other" /var/www/example.com /srv/example.com/current
  [ "$status" -ne 0 ]
}

@test "the rewritten vhost passes nginx -t" {
  command -v nginx >/dev/null || skip "nginx not installed"
  [ -f /etc/nginx/snippets/fastcgi-php.conf ] || skip "no fastcgi-php snippet"
  vhost_to_releases "$T/vhost" /var/www/example.com /srv/example.com/current >/dev/null
  sed -i 's/server_name example.com;/listen 127.0.0.1:18081; server_name example.com;/' "$T/vhost"
  # nginx resolves relative includes (and the distro snippets' own) against the main
  # config's directory, so the test config lives in /etc/nginx, as on a real server.
  # Disposable container: test/run.sh.
  printf 'events {}\nhttp {\n include mime.types;\n include %s;\n}\n' "$T/vhost" > /etc/nginx/dk-migrate-test.conf
  run nginx -t -c /etc/nginx/dk-migrate-test.conf
  rm -f /etc/nginx/dk-migrate-test.conf
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[warn]"* ]]
}

@test "copy_shared makes real copies with the pool user's ownership and a 640 env file" {
  id -u dkmig >/dev/null 2>&1 || useradd --system --user-group --no-create-home dkmig
  O="$T/old"; mkdir -p "$O/wp-content/uploads/2026" "$O/preview"
  echo env > "$O/wp-config-env.php"; echo img > "$O/wp-content/uploads/2026/a.jpg"; echo p > "$O/preview/index.html"
  echo drop > "$O/wp-content/object-cache.php"
  run copy_shared "$O" "$T/base" dkmig $(shared_paths_for wp-content/object-cache.php preview)
  [ "$status" -eq 0 ]
  S="$T/base/shared"
  [ "$(cat "$S/wp-content/uploads/2026/a.jpg")" = img ]
  [ "$(stat -c %i "$S/wp-content/uploads/2026/a.jpg")" != "$(stat -c %i "$O/wp-content/uploads/2026/a.jpg")" ]   # not a hard link
  [ "$(stat -c '%U:%G %a' "$S/wp-config-env.php")" = "root:dkmig 640" ]
  [ "$(stat -c %U "$S/wp-content/uploads/2026/a.jpg")" = dkmig ]
  [ "$(stat -c %U "$S/preview/index.html")" = dkmig ]
  [ -f "$S/wp-content/debug.log" ]                        # created when absent
  [ "$(stat -c %U:%G "$T/base/shared")" = root:root ]
  [ -d "$T/base/releases" ]
}

@test "copy_shared fails on a missing shared path other than debug.log" {
  id -u dkmig >/dev/null 2>&1 || useradd --system --user-group --no-create-home dkmig
  O="$T/old"; mkdir -p "$O/wp-content/uploads"; echo env > "$O/wp-config-env.php"
  run copy_shared "$O" "$T/base" dkmig $(shared_paths_for preview)
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing in the live docroot"*preview* ]]
}
