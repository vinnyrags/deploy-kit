#!/bin/bash
# deploy-kit — assert that a provisioned site actually WORKS.
#
# Every check here exists because something failed silently in a way that
# `nginx -t`, a green deploy, and even a successful login all reported as fine.
# The motivating case: WP_SITEURL was set equal to WP_HOME while core lives in
# /wp, so site_url() resolved to the docroot, wp_login_url() returned a path
# nginx 404s, and /wp/wp-admin/ bounced to a dead ?reauth=1 URL. Logging in
# SUCCEEDED and set a cookie, so it read as a session problem. Nothing logged it.
#
# Runs ON the droplet. Hits the origin directly via --resolve, so it is valid
# before DNS exists and is not answered by a CDN edge cache.
#
#   Usage:  verify-site.sh <slug> <prod_domain> [--env prod|staging|both]
#
# Exit 0 only if every check passed. Any failure exits 1 — this is meant to be
# the last line of provisioning and to fail loudly.
set -uo pipefail

SLUG="${1:?slug}"; DOMAIN="${2:?prod domain}"; shift 2
WANT_ENV="both"
while [ $# -gt 0 ]; do
  case "$1" in
    --env) WANT_ENV="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# GATED=1 in the site conf: the site answers anonymous visitors with a password
# gate (401). Read in a subshell so nothing else in the conf leaks into this run.
SITE_CONF="/etc/deploy-kit/${SLUG}.conf"
GATED=0
[ -r "$SITE_CONF" ] && GATED="$( . "$SITE_CONF" >/dev/null 2>&1; echo "${GATED:-0}" )"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIP=$((SKIP+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# curl straight at this box, never through DNS or a CDN. -k because the origin
# cert is irrelevant to what we are testing here (TLS validity is its own check).
fetch() { # fetch <host> <path> [extra curl args...]
  local host="$1" path="$2"; shift 2
  local scheme=https port=443
  [ -d "/etc/letsencrypt/live/${host}" ] || { scheme=http; port=80; }
  curl -sk --resolve "${host}:80:127.0.0.1" --resolve "${host}:443:127.0.0.1" "$@" "${scheme}://${host}${path}"
}
code() { fetch "$1" "$2" -o /dev/null -w '%{http_code}' "${@:3}"; }

check_env() { # check_env <host> <docroot> <label>
  local host="$1" root="$2" label="$3"
  head_ "── ${label}  (${host})"

  if [ ! -d "$root" ]; then bad "docroot exists" "$root missing"; return; fi
  local WP="sudo -u www-data wp --path=wp"

  # ---- nginx layer: true whether or not WordPress is installed ----------------
  local vhost="/etc/nginx/sites-enabled/${host}"
  if [ -e "$vhost" ]; then
    grep -q 'include snippets/wp-hardening.conf' "$vhost" \
      && ok "hardening snippet included in vhost" \
      || bad "hardening snippet included in vhost" "harden.sh has not patched ${host}"
  else
    bad "vhost present" "$vhost missing"
  fi

  # Absent, this is only a WARNING to nginx — `nginx -t` still says "successful"
  # — and every cached response then collides on one key, so the site serves a
  # single page for every URL. vincentragosta.io, 2026-08-30.
  if grep -rqs 'fastcgi_cache_key' /etc/nginx/; then
    ok "droplet-level fastcgi_cache_key present"
  else
    bad "droplet-level fastcgi_cache_key present" "nginx -t PASSES without it; site would serve one page for all URLs"
  fi

  # Pages that vary per visitor stay out of the shared cache by sending
  # `Cache-Control: private, no-store` — a password gate's unlocked pages are the
  # case that bit (3SOL, 2026-09-30: the first unlock was served to every
  # anonymous visitor). fastcgi_ignore_headers would make nginx cache them anyway,
  # silently.
  if grep -rqs 'fastcgi_ignore_headers' /etc/nginx/; then
    bad "nginx honors Cache-Control from PHP" "fastcgi_ignore_headers is set — no-store pages (gates, per-visitor responses) would be cached and served to everyone"
  else
    ok "nginx honors Cache-Control from PHP"
  fi

  # These locations `deny all`, so they answer 403 even when the file is absent.
  [ "$(code "$host" /xmlrpc.php -X POST)" = 403 ]    && ok "/xmlrpc.php blocked"    || bad "/xmlrpc.php blocked"
  [ "$(code "$host" /wp/xmlrpc.php -X POST)" = 403 ] && ok "/wp/xmlrpc.php blocked" || bad "/wp/xmlrpc.php blocked" "the bare rule does not cover the /wp layout — this path answered 200 on AVFTB production"
  [ "$(code "$host" /wp-config.php)" = 403 ]         && ok "wp-config.php blocked"     || bad "wp-config.php blocked"
  [ "$(code "$host" /wp-config-env.php)" = 403 ]     && ok "wp-config-env.php blocked" || bad "wp-config-env.php blocked" "this file holds DB credentials and salts"
  [ "$(code "$host" /wp-content/uploads/probe.php)" = 403 ] && ok "PHP in uploads denied" || bad "PHP in uploads denied"

  if [ -d "/etc/letsencrypt/live/${host}" ]; then
    if openssl x509 -checkend 604800 -noout -in "/etc/letsencrypt/live/${host}/fullchain.pem" >/dev/null 2>&1; then
      ok "TLS cert present and >7d from expiry"
    else
      bad "TLS cert present and >7d from expiry" "renewal may be failing"
    fi
  else
    skip "TLS cert (not issued yet)"
  fi

  # ---- WordPress layer -------------------------------------------------------
  if [ ! -f "$root/wp/wp-load.php" ]; then
    # Nothing is deployed yet, so an empty docroot answering 403 is the correct
    # state, not a fault. Failing here on a fresh provision would train people to
    # ignore this script, which is worse than not having it.
    skip "WordPress checks (core not deployed yet)"
    skip "homepage / cache checks (nothing deployed yet)"
    return
  fi

  # Does the site actually serve? An empty docroot answers 403 "directory index
  # is forbidden" and every downstream check then reports something misleading.
  # Name the real problem instead.
  local hc; hc="$(code "$host" /)"
  if [ "$GATED" = 1 ]; then
    # A gated site must answer anonymous visitors with the gate — a 200 here is
    # the gate off or bypassed, which is the failure worth catching.
    case "$hc" in
      401) ok "gate answers anonymous visitors (401)" ;;
      200) bad "gate answers anonymous visitors" "200 — the site is being served ungated" ;;
      403) bad "gate answers anonymous visitors" "403 — code is deployed but nothing is served. Is index.php present in the docroot?" ;;
      *)   bad "gate answers anonymous visitors" "got ${hc}, expected 401" ;;
    esac
  else
    case "$hc" in
      200|301|302) ok "homepage responds (${hc})" ;;
      403) bad "homepage responds" "403 — code is deployed but nothing is served. Is index.php present in the docroot?" ;;
      *)   bad "homepage responds" "got ${hc}" ;;
    esac
  fi
  if ! (cd "$root" && $WP core is-installed >/dev/null 2>&1); then
    skip "WordPress checks (core deployed, not installed)"
    bad "installer is NOT publicly reachable" "an uninstalled WordPress serves /wp/wp-admin/install.php to anyone — complete the install or take the site offline"
    return
  fi

  local home site login
  home="$(cd "$root" && $WP eval 'echo home_url();' 2>/dev/null)"
  site="$(cd "$root" && $WP eval 'echo site_url();' 2>/dev/null)"
  login="$(cd "$root" && $WP eval 'echo wp_login_url();' 2>/dev/null)"

  # THE bug this script was written for.
  if [ "$site" = "${home}/wp" ]; then
    ok "site_url() == home_url() . '/wp'"
  else
    bad "site_url() == home_url() . '/wp'" "home=${home} site=${site} — set WP_SITEURL to WP_HOME . '/wp'; the dashboard is unreachable as-is"
  fi

  # The template sets FORCE_SSL_ADMIN, so wp-login.php 302s to https. Before
  # certbot has run there is no 443 listener and the redirect cannot complete —
  # that is a provisioning-order artifact, not a broken site. Say so rather than
  # reporting a failure the operator cannot act on.
  local have_tls=0; [ -d "/etc/letsencrypt/live/${host}" ] && have_tls=1
  local login_path="${login#*://*/}"
  if [ "$have_tls" = 0 ]; then
    skip "wp_login_url() resolves (no TLS yet; FORCE_SSL_ADMIN needs https)"
  else
    local lc; lc="$(code "$host" "/${login_path}" -L)"
    [ "$lc" = 200 ] && ok "wp_login_url() resolves (${lc})" \
                    || bad "wp_login_url() resolves" "${login} -> ${lc}; login page is not served at the URL WordPress advertises"
  fi

  # Prove the dashboard is genuinely reachable, not merely that a cookie is set.
  # A wrong WP_SITEURL still sets a valid cookie and still 302s — it just 302s
  # somewhere that 404s.
  local cookie admin_code
  cookie="$(cd "$root" && $WP eval '
    $u = get_users(["role" => "administrator", "number" => 1]);
    if (!$u) { exit(1); }
    echo LOGGED_IN_COOKIE . "=" . wp_generate_auth_cookie($u[0]->ID, time() + 300, "logged_in");
  ' 2>/dev/null)"
  if [ "$have_tls" = 0 ]; then
    skip "dashboard reachability (no TLS yet; FORCE_SSL_ADMIN needs https)"
  elif [ -n "$cookie" ]; then
    admin_code="$(code "$host" /wp/wp-admin/ -b "$cookie" -L)"
    [ "$admin_code" = 200 ] && ok "/wp/wp-admin/ reaches the dashboard (${admin_code})" \
                            || bad "/wp/wp-admin/ reaches the dashboard" "got ${admin_code} — a reauth bounce to a 404 looks exactly like this"
  else
    skip "dashboard reachability (no administrator account)"
  fi

  # A gated homepage is a 401 and never cached, so it cannot show whether the
  # cache is engaged. Two things instead: the gate itself must not come from
  # cache, and /robots.txt — a public 200 rendered by PHP — proves the cache
  # works. (Not a 404: WordPress sends no-store on every 404, and the vhost's
  # X-FastCGI-Cache add_header does not apply to 404 responses at all.)
  local probe=/
  if [ "$GATED" = 1 ]; then
    fetch "$host" / -o /dev/null
    local gs; gs="$(fetch "$host" / -o /dev/null -D - | grep -i '^x-fastcgi-cache:' | tr -d '\r' | awk '{print $2}')"
    [ "$gs" = HIT ] && bad "gate page is never served from cache" "X-FastCGI-Cache: HIT on an anonymous request to /" \
                    || ok "gate page is never served from cache"
    probe=/robots.txt
  fi

  # Micro-cache actually engaged. Query strings are in the skip-map, so use a
  # bare path and prime it first.
  fetch "$host" "$probe" -o /dev/null
  local cs; cs="$(fetch "$host" "$probe" -o /dev/null -D - | grep -i '^x-fastcgi-cache:' | tr -d '\r' | awk '{print $2}')"
  case "$cs" in
    HIT|MISS|BYPASS|EXPIRED) ok "FastCGI micro-cache active (${cs})" ;;
    "") if [ "$hc" = 403 ]; then
          skip "FastCGI micro-cache (nothing is served, see above)"
        elif [ "$GATED" = 1 ]; then
          bad "FastCGI micro-cache active" "no X-FastCGI-Cache header on ${probe} — is the gate letting robots.txt through?"
        else
          bad "FastCGI micro-cache active" "no X-FastCGI-Cache header — page caching is not engaged"
        fi ;;
    *) bad "FastCGI micro-cache active" "unexpected status: ${cs}" ;;
  esac
}

echo "deploy-kit verify — ${SLUG} (${DOMAIN})"
case "$WANT_ENV" in
  prod)    check_env "$DOMAIN" "/var/www/${DOMAIN}/public" "production" ;;
  staging) check_env "staging.${DOMAIN}" "/var/www/staging.${DOMAIN}/public" "staging" ;;
  both)    check_env "$DOMAIN" "/var/www/${DOMAIN}/public" "production"
           check_env "staging.${DOMAIN}" "/var/www/staging.${DOMAIN}/public" "staging" ;;
  *) echo "--env must be prod|staging|both" >&2; exit 2 ;;
esac

printf '\n\033[1mverify: %d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || { echo "VERIFY FAILED — do not call this site provisioned." >&2; exit 1; }
