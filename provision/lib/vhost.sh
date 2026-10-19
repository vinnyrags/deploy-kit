# deploy-kit — vhost editing helpers. Sourced by provision/harden.sh and the tests.

# add_include_after_hardening <vhost_file> <snippet_name>
#   Inserts `include snippets/<name>.conf;` on the line after each
#   `include snippets/wp-hardening.conf;`, with the same indentation. Idempotent: a file
#   that already includes the snippet is left alone. Placement matters — the hardening
#   include sits at the top of the server block, ahead of the generic PHP location, and
#   regex locations are first-match. Prints "added", "present" or "no-anchor".
add_include_after_hardening() {
  local file="$1" name="$2"
  if grep -q "include snippets/${name}.conf;" "$file"; then echo present; return 0; fi
  if ! grep -q "include snippets/wp-hardening.conf;" "$file"; then echo no-anchor; return 0; fi
  awk -v inc="include snippets/${name}.conf;" '
    { print }
    /^[[:space:]]*include snippets\/wp-hardening\.conf;/ {
      match($0, /^[[:space:]]*/); print substr($0, 1, RLENGTH) inc
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  echo added
}
