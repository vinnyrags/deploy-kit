#!/bin/bash
# deploy-kit — fail2ban jail for a host that is NOT behind Cloudflare. As root.
#
#     fail2ban-direct.sh <server_name> --name <short>   e.g. packages.example.com --name packages
#
# Bans an IP from 80/443 for a day after 5 nginx deny-rule hits in 10 minutes against
# that one server_name. ONLY for DNS-only (grey-cloud) hosts: behind Cloudflare the
# client IP of the connection is Cloudflare's, so a ban would land on the edge, not the
# scanner. It counts deny-rule hits ("access forbidden by rule") and nothing else — a
# Composer client with bad credentials gets a 401, which never matches.
# Reads /var/log/nginx/error.log by polling (Ubuntu's fail2ban default backend is the
# journal, which nginx does not write to). Idempotent; test with fail2ban-regex first:
#     fail2ban-regex /var/log/nginx/error.log /etc/fail2ban/filter.d/nginx-<short>-forbidden.conf
set -euo pipefail
HOST="${1:?server_name}"; shift
NAME=""
while [ $# -gt 0 ]; do case "$1" in --name) NAME="${2:?}"; shift ;; *) echo "unknown arg: $1" >&2; exit 2 ;; esac; shift; done
[ -n "$NAME" ] || { echo "--name <short> required" >&2; exit 2; }
command -v fail2ban-client >/dev/null || { echo "fail2ban not installed" >&2; exit 1; }
esc="$(printf '%s' "$HOST" | sed 's/\./\\./g')"

cat > "/etc/fail2ban/filter.d/nginx-${NAME}-forbidden.conf" <<CONF
# deploy-kit — nginx deny-rule hits against ${HOST} only (direct host, real client IPs).
[Definition]
datepattern = {^LN-BEG}%%Y/%%m/%%d %%H:%%M:%%S
failregex = \\[error\\] \\d+#\\d+: \\*\\d+ access forbidden by rule, client: <HOST>, server: ${esc},
ignoreregex =
CONF

cat > "/etc/fail2ban/jail.d/nginx-${NAME}.local" <<CONF
# deploy-kit — scanner ban for ${HOST} (not behind Cloudflare). See provision/fail2ban-direct.sh.
[nginx-${NAME}]
enabled  = true
backend  = polling
logpath  = /var/log/nginx/error.log
filter   = nginx-${NAME}-forbidden
port     = http,https
maxretry = 5
findtime = 10m
bantime  = 1d
CONF

fail2ban-client -t >/dev/null || { echo "fail2ban config test FAILED" >&2; exit 1; }
systemctl reload fail2ban
fail2ban-client status "nginx-${NAME}" | sed 's/^/   /'
