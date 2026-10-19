#!/bin/bash
# deploy-kit — prove every production site actually has its page cache. Run from
# your Mac (or anywhere with curl); touches nothing, needs no SSH.
#
#   Usage:  fleet-cache-check.sh [sites-file]
#           default: $FLEET_CACHE_SITES, else ~/.claude/ops/fleet-cache.sites — the list
#           lives outside this (public) repo; format is documented in its header and in
#           docs/droplet-cache-convention.md.
#   Exit:   0 all pass · 1 any FAIL
#
# Why it exists: the cache convention (docs/droplet-cache-convention.md) was written
# down in July, but nothing checked that sites followed it — a hand-provisioned site
# ran with no cache of any kind for weeks and nobody knew until visitors saw it.
#
# For an `expect = cache` site, each path is fetched twice with no query string:
#   - both must be 200,
#   - the second must report X-FastCGI-Cache HIT (or STALE/UPDATING),
#   - every path must return a different body. Identical bodies across paths are the
#     signature of a missing fastcgi_cache_key — the whole site serving one cached
#     page — which `nginx -t` only warns about. Bodies, not <title>s: some themes
#     print one site-wide title on every page.
# A 401 (an access gate) is reported SKIP: a gate cookie bypasses the cache by design.
set -uo pipefail

SITES="${1:-${FLEET_CACHE_SITES:-$HOME/.claude/ops/fleet-cache.sites}}"
[ -r "$SITES" ] || { echo "sites file not found: $SITES" >&2; exit 2; }
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/141 Safari/537.36 deploy-kit-cache-check"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0

fetch() {  # fetch <url> → sets $code $cache $body
  curl -s --max-time 30 -A "$UA" -D "$TMP/h" -o "$TMP/b" "$1" >/dev/null 2>&1
  code="$(awk 'NR==1{print $2}' "$TMP/h" 2>/dev/null)"
  cache="$(grep -i '^x-fastcgi-cache:' "$TMP/h" 2>/dev/null | awk '{print toupper($2)}' | tr -d '\r')"
  body="$(cksum < "$TMP/b" 2>/dev/null | awk '{print $1}')"
}

while read -r host expect paths; do
  case "$host" in ''|\#*) continue ;; esac
  status="PASS"; notes=""; bodies=""

  for p in $paths; do
    url="https://${host}${p}"
    fetch "$url"
    if [ "$code" = "401" ]; then status="SKIP"; notes="gated (401)"; break; fi
    fetch "$url"   # second pass: should now be cached
    if [ "$code" != "200" ]; then status="FAIL"; notes+=" ${p}=HTTP${code:-none}"; continue; fi

    if [ "$expect" = "cache" ]; then
      case "$cache" in
        HIT|STALE|UPDATING) ;;
        "") status="FAIL"; notes+=" ${p}=no-cache-header" ;;
        *)  status="FAIL"; notes+=" ${p}=${cache}" ;;
      esac
      bodies+="${body}"$'\n'
    elif [ -n "$cache" ]; then
      status="FAIL"; notes+=" ${p}=cache-present(${cache})-but-expected-none"
    fi
  done

  # Distinct bodies: two or more paths with one body = one page served for all URLs.
  n="$(printf '%s' "$bodies" | grep -c . || true)"
  if [ "$status" != "SKIP" ] && [ "$n" -gt 1 ]; then
    u="$(printf '%s' "$bodies" | sort -u | grep -c . || true)"
    [ "$u" -lt "$n" ] && { status="FAIL"; notes+=" identical-bodies(${u}/${n}):missing-cache-key?"; }
  fi

  [ "$status" = "FAIL" ] && fails=$((fails + 1))
  printf '%-5s %-30s %-6s%s\n' "$status" "$host" "$expect" "${notes:+ —$notes}"
done < "$SITES"

exit $(( fails > 0 ))
