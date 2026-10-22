#!/usr/bin/env bats
# provision/lib/audit.sh — every check must FAIL (or WARN) on an un-hardened box and PASS
# on a hardened one. A drift check that cannot fail proves nothing.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export AUDIT_ROOT="$(mktemp -d)"
  source "$KIT/provision/lib/audit.sh"
  mkdir -p "$AUDIT_ROOT"/etc/{nginx/sites-available,nginx/sites-enabled,apt/apt.conf.d,systemd/journald.conf.d,php/8.4/fpm/pool.d} "$AUDIT_ROOT/var/run"
}
teardown() { rm -rf "$AUDIT_ROOT"; }
status_of() { "$@" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//'; }

@test "nginx.tls: FAIL while TLSv1/1.1 are listed, PASS on 1.2+1.3 only" {
  printf 'http {\n  ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # POODLE\n}\n' > "$AUDIT_ROOT/etc/nginx/nginx.conf"
  [ "$(status_of audit_nginx_tls)" = FAIL ]
  printf 'http {\n  ssl_protocols TLSv1.2 TLSv1.3;\n}\n' > "$AUDIT_ROOT/etc/nginx/nginx.conf"
  [ "$(status_of audit_nginx_tls)" = PASS ]
}

@test "nginx.tokens: a commented-out server_tokens does not count" {
  printf 'http {\n  # server_tokens off;\n}\n' > "$AUDIT_ROOT/etc/nginx/nginx.conf"
  [ "$(status_of audit_nginx_tokens)" = FAIL ]
  printf 'http {\n  server_tokens off;\n}\n' > "$AUDIT_ROOT/etc/nginx/nginx.conf"
  [ "$(status_of audit_nginx_tokens)" = PASS ]
}

@test "nginx.catchall: FAIL without a rejecting 443 default_server" {
  printf 'server { listen 443 ssl; server_name a.example; }\n' > "$AUDIT_ROOT/etc/nginx/sites-available/a"
  ln -s "$AUDIT_ROOT/etc/nginx/sites-available/a" "$AUDIT_ROOT/etc/nginx/sites-enabled/a"
  [ "$(status_of audit_nginx_catchall)" = FAIL ]
  printf 'server {\n listen 443 ssl default_server;\n ssl_reject_handshake on;\n return 444;\n}\n' > "$AUDIT_ROOT/etc/nginx/sites-available/00-catchall"
  ln -s "$AUDIT_ROOT/etc/nginx/sites-available/00-catchall" "$AUDIT_ROOT/etc/nginx/sites-enabled/00-catchall"
  [ "$(status_of audit_nginx_catchall)" = PASS ]
}

@test "nginx.links: a real file in sites-enabled is a FAIL that names it" {
  echo 'server {}' > "$AUDIT_ROOT/etc/nginx/sites-enabled/example.com"
  run audit_nginx_symlinks
  [[ "$output" == FAIL* ]]
  [[ "$output" == *example.com* ]]
}

@test "os.autoreboot: FAIL when the reboot line is only a comment" {
  echo '//Unattended-Upgrade::Automatic-Reboot "true";' > "$AUDIT_ROOT/etc/apt/apt.conf.d/50unattended-upgrades"
  [ "$(status_of audit_os_autoreboot)" = FAIL ]
  echo 'Unattended-Upgrade::Automatic-Reboot "true";' > "$AUDIT_ROOT/etc/apt/apt.conf.d/52local"
  [ "$(status_of audit_os_autoreboot)" = PASS ]
}

@test "os.reboot: a reboot pending for days is a FAIL, a fresh one a WARN" {
  touch "$AUDIT_ROOT/var/run/reboot-required"
  [ "$(status_of audit_os_reboot_pending)" = WARN ]
  touch -d '10 days ago' "$AUDIT_ROOT/var/run/reboot-required"
  [ "$(status_of audit_os_reboot_pending)" = FAIL ]
}

@test "php.users: a pool running as www-data is flagged" {
  printf '[site]\nuser = www-data\ngroup = www-data\n' > "$AUDIT_ROOT/etc/php/8.4/fpm/pool.d/site.conf"
  [ "$(status_of audit_php_pool_users)" = WARN ]
  sed -i 's/www-data/site/g' "$AUDIT_ROOT/etc/php/8.4/fpm/pool.d/site.conf"
  [ "$(status_of audit_php_pool_users)" = PASS ]
}

@test "php.secrets: wrong group or mode is a FAIL; root:<pool user> 640 passes" {
  id -u dkaudit >/dev/null 2>&1 || useradd --system --user-group --no-create-home dkaudit
  mkdir -p "$AUDIT_ROOT/srv/site"; echo x > "$AUDIT_ROOT/srv/site/wp-config-env.php"
  chown root:www-data "$AUDIT_ROOT/srv/site/wp-config-env.php"; chmod 644 "$AUDIT_ROOT/srv/site/wp-config-env.php"
  [ "$(echo "/srv/site/wp-config-env.php dkaudit" | status_of audit_php_secrets)" = FAIL ]
  chown root:dkaudit "$AUDIT_ROOT/srv/site/wp-config-env.php"; chmod 640 "$AUDIT_ROOT/srv/site/wp-config-env.php"
  [ "$(echo "/srv/site/wp-config-env.php dkaudit" | status_of audit_php_secrets)" = PASS ]
  [ "$(echo "/srv/missing/wp-config-env.php dkaudit" | status_of audit_php_secrets)" = FAIL ]
}

@test "mail.conf: a world-readable relay config is a FAIL" {
  echo 'password secret' > "$AUDIT_ROOT/etc/msmtprc"; chmod 644 "$AUDIT_ROOT/etc/msmtprc"
  [ "$(status_of audit_mail_conf)" = FAIL ]
  chmod 640 "$AUDIT_ROOT/etc/msmtprc"
  [ "$(status_of audit_mail_conf)" = PASS ]
}

@test "the audit runner passes bash -n" {
  run bash -n "$KIT/provision/audit.sh"
  [ "$status" -eq 0 ]
}

@test "sec.admin: WARN until a sudo user has a key AND a sudoers rule" {
  mkdir -p "$AUDIT_ROOT/etc/sudoers.d" "$AUDIT_ROOT/home/ops/.ssh"
  printf 'root:x:0:0::/root:/bin/bash\nops:x:1000:1000::/home/ops:/bin/bash\n' > "$AUDIT_ROOT/etc/passwd"
  printf 'sudo:x:27:ops\n' > "$AUDIT_ROOT/etc/group"
  [ "$(status_of audit_ssh_admin)" = WARN ]                       # in sudo, no key
  echo 'ssh-ed25519 AAAA ops' > "$AUDIT_ROOT/home/ops/.ssh/authorized_keys"
  [ "$(status_of audit_ssh_admin)" = WARN ]                       # key, no sudoers rule
  echo 'ops ALL=(ALL) NOPASSWD:ALL' > "$AUDIT_ROOT/etc/sudoers.d/90-deploy-kit-ops"
  [ "$(status_of audit_ssh_admin)" = PASS ]
}
