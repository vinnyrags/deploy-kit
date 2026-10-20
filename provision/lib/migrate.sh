# deploy-kit — helpers for moving a site from an in-place docroot to LAYOUT=releases.
# Sourced by provision/migrate-to-releases.sh and the tests. Pure: they rewrite or copy
# only what they are given and touch no services.

# vhost_to_releases <vhost file> <old docroot> <new current>
#   Point a vhost at a releases layout:
#     - `root <old>;` becomes `root <new current>;`;
#     - every `fastcgi_param SCRIPT_FILENAME …` and `DOCUMENT_ROOT …` line is removed, and
#       both are set from $realpath_root right after the PHP location's last
#       `include fastcgi_params;` (or the fastcgi-php snippet).
#   $realpath_root resolves the `current` symlink per request, so PHP-FPM and OPcache see the
#   real release path and a switch takes effect atomically; $document_root would keep
#   serving the release OPcache first saw. Placing them after the includes matters,
#   because PHP-FPM keeps the last value of a repeated param, and fastcgi_params sets
#   DOCUMENT_ROOT itself. Prints "rewritten" or "already" (idempotent).
vhost_to_releases() {
  local file="$1" old="$2" new="$3"
  if grep -qE "^[[:space:]]*root[[:space:]]+${new//\//\\/};" "$file" \
     && grep -qE 'fastcgi_param[[:space:]]+SCRIPT_FILENAME[[:space:]]+\$realpath_root' "$file"; then
    echo already; return 0
  fi
  grep -qE "^[[:space:]]*root[[:space:]]+${old//\//\\/};" "$file" \
    || { echo "no 'root ${old};' in $file" >&2; return 1; }
  awk -v old="$old" -v new="$new" '
    function indent(s) { match(s, /^[[:space:]]*/); return substr(s, 1, RLENGTH) }
    # The include after which the realpath params go: the last fastcgi_params include, or
    # the fastcgi-php snippet when there is none (pass 1 finds its line number).
    NR == FNR {
      if ($0 ~ /^[[:space:]]*include[[:space:]]+fastcgi_params;/) anchor = FNR
      else if (!anchor && $0 ~ /^[[:space:]]*include[[:space:]]+snippets\/fastcgi-php\.conf;/) snip = FNR
      next
    }
    FNR == 1 { if (!anchor) anchor = snip }
    $0 ~ "^[[:space:]]*root[[:space:]]+" old ";" { print indent($0) "root " new ";"; next }
    /^[[:space:]]*fastcgi_param[[:space:]]+(SCRIPT_FILENAME|DOCUMENT_ROOT)[[:space:]]/ { next }
    {
      print
      if (FNR == anchor) {
        i = indent($0)
        print i "# $realpath_root, not $document_root: resolve `current` per request, so PHP and"
        print i "# OPcache see the real release path and a switch takes effect atomically."
        print i "fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;"
        print i "fastcgi_param DOCUMENT_ROOT $realpath_root;"
      }
    }' "$file" "$file" > "$file.dk-tmp" && mv "$file.dk-tmp" "$file"
  echo rewritten
}

# shared_paths_for <extra...>: the paths every mythus-ix release links from shared/.
shared_paths_for() { printf '%s\n' wp-config-env.php wp-content/uploads wp-content/debug.log "$@"; }

# copy_shared <old docroot> <base> <pool user> <path...>
#   Copy each path from the live docroot into <base>/shared/ (cp -a: real copies, never
#   hard links — the old docroot must stay a complete fallback). A missing debug.log is
#   created; any other missing path is an error. Ownership: everything the pool user
#   writes is theirs; wp-config-env.php is 640 root:<user>; shared/ itself root:root.
copy_shared() {
  local old="$1" base="$2" user="$3"; shift 3
  local p
  mkdir -p "$base/releases" "$base/shared/wp-content"
  chown root:root "$base" "$base/releases" "$base/shared" "$base/shared/wp-content"
  chmod 755 "$base" "$base/releases" "$base/shared" "$base/shared/wp-content"
  for p in "$@"; do
    mkdir -p "$(dirname "$base/shared/$p")"
    if [ -e "$old/$p" ]; then
      rm -rf "${base:?}/shared/$p"
      cp -a "$old/$p" "$base/shared/$p"
    elif [ "$p" = wp-content/debug.log ]; then
      : > "$base/shared/$p"
    else
      echo "missing in the live docroot: $old/$p" >&2; return 1
    fi
    [ "$p" = wp-config-env.php ] || chown -R "${user}:${user}" "$base/shared/$p"
  done
  chown "root:${user}" "$base/shared/wp-config-env.php" && chmod 640 "$base/shared/wp-config-env.php"
}
