#!/usr/bin/env bats
# provision/lib/baseline.sh — the renders and the in-place nginx.conf editor. The last
# tests apply the nginx baseline to the container's STOCK distro nginx.conf and require
# nginx -t clean and the audit to pass: what baseline.sh builds is what audit.sh checks.

setup() {
  KIT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(mktemp -d)"
  source "$KIT/provision/lib/baseline.sh"
  cat > "$T/nginx.conf" <<'N'
http {
	sendfile on;
	# server_tokens off;
	ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3; # Dropping SSLv3, ref: POODLE
	access_log /var/log/nginx/access.log;
	gzip on;
	# gzip_vary on;
	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}
N
}
teardown() { rm -rf "$T"; }

@test "nginx_set replaces the active line in place, keeping its indentation" {
  run nginx_set "$T/nginx.conf" ssl_protocols 'TLSv1.2 TLSv1.3'
  [ "$output" = set ]
  grep -qP '^\tssl_protocols TLSv1.2 TLSv1.3;$' "$T/nginx.conf"
  [ "$(grep -c ssl_protocols "$T/nginx.conf")" -eq 1 ]
}

@test "nginx_set ignores a commented-out line and adds before the conf.d include" {
  run nginx_set "$T/nginx.conf" server_tokens off
  [ "$output" = added ]
  grep -q '# server_tokens off;' "$T/nginx.conf"                     # distro comment untouched
  [ "$(grep -n '^\s*server_tokens off;' "$T/nginx.conf" | cut -d: -f1)" -lt \
    "$(grep -n 'include /etc/nginx/conf.d' "$T/nginx.conf" | cut -d: -f1)" ]
}

@test "nginx_set is idempotent" {
  nginx_set "$T/nginx.conf" gzip_vary on >/dev/null
  cp "$T/nginx.conf" "$T/once"
  run nginx_set "$T/nginx.conf" gzip_vary on
  [ "$output" = unchanged ]
  cmp -s "$T/once" "$T/nginx.conf"
}

@test "nginx_ensure_log_format defines timed before access_log, once" {
  run nginx_ensure_log_format "$T/nginx.conf"
  [ "$output" = added ]
  [ "$(grep -n 'log_format timed' "$T/nginx.conf" | cut -d: -f1)" -lt "$(grep -n 'access_log' "$T/nginx.conf" | cut -d: -f1)" ]
  grep -q 'cache=$upstream_cache_status' "$T/nginx.conf"
  run nginx_ensure_log_format "$T/nginx.conf"
  [ "$output" = present ]
  [ "$(grep -c 'log_format timed' "$T/nginx.conf")" -eq 1 ]
}

@test "render_unattended only adds the PPA origin when given one" {
  run render_unattended 09:00
  [[ "$output" == *'Automatic-Reboot "true"'* ]]
  [[ "$output" == *'Automatic-Reboot-Time "09:00"'* ]]
  [[ "$output" != *Origins-Pattern* ]]
  run render_unattended 04:30 "o=LP-PPA-ondrej-php,a=noble"
  [[ "$output" == *'Origins-Pattern { "o=LP-PPA-ondrej-php,a=noble"; }'* ]]
}

@test "stock distro nginx.conf + baseline + catch-all: nginx -t clean, no warnings" {
  command -v nginx >/dev/null || skip "nginx not installed"
  [ -f /etc/nginx/nginx.conf ] || skip "no distro nginx.conf"
  while IFS=$'\t' read -r n v; do nginx_set /etc/nginx/nginx.conf "$n" "$v" >/dev/null; done < <(baseline_nginx_directives)
  nginx_ensure_log_format /etc/nginx/nginx.conf >/dev/null
  nginx_set /etc/nginx/nginx.conf access_log "/var/log/nginx/access.log timed" >/dev/null
  rm -f /etc/nginx/sites-enabled/default        # provision-base drops the distro default
  render_catchall > /etc/nginx/sites-available/00-catchall
  ln -sfn /etc/nginx/sites-available/00-catchall /etc/nginx/sites-enabled/00-catchall
  run nginx -t
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"[warn]"* ]]
}

@test "what the baseline builds is what the audit checks: every nginx check passes" {
  [ -f /etc/nginx/sites-enabled/00-catchall ] || skip "runs after the nginx -t test, in the container"
  AUDIT_ROOT=""
  source "$KIT/provision/lib/audit.sh"
  for c in audit_nginx_tls audit_nginx_tokens audit_nginx_gzip audit_nginx_logformat audit_nginx_catchall audit_nginx_symlinks; do
    run "$c"; echo "$output"
    [[ "$output" == PASS* ]]
  done
}
