#!/bin/bash
# deploy-kit — LAYOUT=releases: build each deploy off to the side, switch atomically,
# roll back on a failed smoke test. Sourced by deploy.sh after common.sh.
#
# Layout, for a branch whose DEPLOY_DIR is <base>/current:
#
#   <base>/releases/<UTC stamp>-<sha8>/   one per deploy; root-owned, read-only to PHP
#   <base>/shared/                        mutable state every release links to
#   <base>/current -> releases/<…>        the docroot nginx serves ($realpath_root)
#
# Why: an in-place deploy checks out new PHP into the live docroot and then spends
# a minute running composer and npm there, so the site serves new code against old
# vendor/ and dist/ the whole time, and a failure part-way leaves it in that state
# with nothing to roll back to. Here, nothing the site serves changes until a single
# rename(2) of the `current` symlink; a failed smoke test renames it back.
#
# Read-only code: releases are root:root, so a PHP RCE cannot write a backdoor into
# the codebase. Everything PHP must write lives in shared/ (the profile names those
# paths in profile_shared_paths).
#
# Per-branch opt-in in the site conf:
#   declare -A LAYOUT=( [develop]=releases )        # default: inplace
#   declare -A DEPLOY_DIR=( [develop]=/srv/staging.example.com/current … )
#   KEEP_RELEASES=3

# <base> for a DEPLOY_DIR that must end in /current.
release_base() {
  case "$1" in
    */current) dirname "$1" ;;
    *) echo "LAYOUT=releases needs DEPLOY_DIR to end in /current (got $1)" >&2; return 1 ;;
  esac
}

# Link a release's shared paths to <base>/shared/<path>. A path the repo also
# ships (e.g. an empty uploads/ dir) is replaced by the link.
release_link_shared() {
  local rel="$1" base="$2" branch="${3:-}" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$base/shared/$p" ] || { log "shared/$p missing — create it before the first release"; return 1; }
    mkdir -p "$(dirname "$rel/$p")"
    rm -rf "${rel:?}/$p"
    ln -s "$base/shared/$p" "$rel/$p"
  done < <(profile_shared_paths "$branch")
}

# Point <base>/current at a release with one atomic rename.
release_switch() {
  local base="$1" rel="$2"
  ln -sfn "$rel" "$base/.current.tmp"
  mv -T "$base/.current.tmp" "$base/current"
}

# Keep the newest KEEP_RELEASES (default 3), never the live one or the one before it.
release_prune() {
  local base="$1" keep="${KEEP_RELEASES:-3}" live prev r i=0
  live="$(readlink -f "$base/current" || true)"
  prev="${2:-}"
  while IFS= read -r r; do
    i=$((i + 1))
    [ "$i" -le "$keep" ] && continue
    [ "$base/releases/$r" = "$live" ] && continue
    [ "$base/releases/$r" = "$prev" ] && continue
    rm -rf "${base:?}/releases/${r:?}"
    log "pruned release $r"
  done < <(ls -1 "$base/releases" | sort -r)
}

release_deploy() {
  local branch="$1" dest="$2" env="$3" rev="$4"
  local base rel prev stamp
  base="$(release_base "$dest")"
  [ -d "$base/shared" ] || { log "no $base/shared — run the one-time migration first"; return 1; }
  mkdir -p "$base/releases"

  stamp="$(date -u +%Y%m%d-%H%M%S)-${rev:0:8}"
  rel="$base/releases/$stamp"
  prev=""; [ -L "$base/current" ] && prev="$(readlink -f "$base/current")"

  log "release $stamp (previous: ${prev:+$(basename "$prev")})"
  mkdir -p "$rel"
  # git archive writes exactly the tracked tree at this commit: nothing deleted from
  # the repo can survive into a release, so no index bookkeeping is needed.
  # Every step returns explicitly on failure: deploy.sh runs under `set -e`, but bash
  # ignores errexit inside a function called from a condition, and a release that
  # half-built must never reach the switch below.
  local fail="release left unswitched: $rel"
  git --git-dir="$BARE" archive "$rev" | tar -x -C "$rel" || { log "archive failed — $fail"; return 1; }
  release_link_shared "$rel" "$base" "$branch"           || { log "$fail"; return 1; }
  # Shared secrets belong to this environment's pool user (see pool_user).
  local user; user="$(pool_user "$branch")"
  lock_secrets "$base/shared" "$user"

  # Build in the new release. If this fails the site has not changed at all.
  profile_build "$rel"                                   || { log "build failed — $fail"; return 1; }
  find "$rel" -name node_modules -type d -prune -exec rm -rf {} +   # build-time only
  rm -f "$rel/auth.json"                                            # build-time only

  # Read-only to PHP: root owns the code; the world (incl. www-data) can only read.
  chown -R root:root "$rel" && chmod -R u=rwX,go=rX "$rel" || { log "permissions failed — $fail"; return 1; }

  # Does WordPress load from this tree at all? Catches a missing vendor/ or a fatal
  # in mu-plugins before anything is switched.
  wp --path="$rel/wp" --allow-root --skip-plugins --skip-themes eval 'echo "ok";' >/dev/null \
    || { log "pre-switch check failed — release left unswitched: $rel"; return 1; }

  release_switch "$base" "$rel"
  log "switched current -> $stamp"
  profile_activate "$branch" "$base/current"

  if ! smoke_test "$base/current" "$env" "$user"; then
    if [ -n "$prev" ] && [ -d "$prev" ]; then
      release_switch "$base" "$prev"
      profile_activate "$branch" "$base/current"
      log "ROLLED BACK to $(basename "$prev")"
    fi
    return 1
  fi

  release_prune "$base" "$prev"
}

# Point current at the previous release (by name order) and activate it.
release_rollback() {
  local branch="$1" dest="$2" base live target
  base="$(release_base "$dest")"
  live="$(basename "$(readlink -f "$base/current")")"
  target="$(ls -1 "$base/releases" | sort -r | awk -v l="$live" 'f{print; exit} $0==l{f=1}')"
  [ -n "$target" ] || { log "no release older than $live"; return 1; }
  release_switch "$base" "$base/releases/$target"
  profile_activate "$branch" "$base/current"
  log "rolled back: $live -> $target"
}
