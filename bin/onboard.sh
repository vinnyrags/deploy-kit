#!/bin/bash
# deploy-kit — one-command onboarding of a repo into the deploy pipeline. Run from
# your Mac. Folds together the per-site delivery wiring: a dedicated deploy key,
# the forced-command authorized_keys line on the droplet, the three GitHub secrets,
# and the caller workflow in the repo. (The droplet-side infra + hook are done by
# provision/new-site.sh.)
#
#   Usage:  onboard.sh <repo_dir> <gh_repo> <droplet_ip> <bare_slug> [ssh_target]
#     repo_dir     local checkout, e.g. ~/Projects/.../aviewfromthebridge
#     gh_repo      e.g. arthousenewyork/a-view-from-the-bridge
#     droplet_ip   e.g. 203.0.113.10
#     bare_slug    /var/repo/<slug>.git on the droplet, e.g. aviewfromthebridge
#     ssh_target   how YOU reach the box to install the key (default root@<droplet_ip>).
#                  Once ssh-admin.sh --lock-root has run, root accepts only the CI keys:
#                  pass the admin user or its ssh alias (e.g. admin@203.0.113.10).
#                  The key goes into root's authorized_keys via sudo either way.
#
# Requires: gh (authed, with `workflow` scope), ssh to <ssh_target> with sudo.
set -euo pipefail
REPO_DIR="${1:?repo dir}"; GH_REPO="${2:?gh repo}"; DROPLET="${3:?droplet ip}"; SLUG="${4:?bare slug}"
TARGET="${5:-root@${DROPLET}}"
KEY="$(mktemp -d)/deploy-${SLUG}"
BARE="/var/repo/${SLUG}.git"

echo ">> generating deploy key"
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "deploy-${SLUG}-ci" -q

echo ">> installing forced-command key on ${TARGET} (git-receive-pack only, one repo)"
# The key line is built here and sent as STDIN DATA, never interpolated into the
# remote command string. Passing it as an argument means the remote shell
# re-parses the escaped quotes, and it can silently swallow the command="..."
# prefix — leaving a line that still contains the key and the comment, so a grep
# for the comment finds it, but with no forced command and a broken first field.
# The push then fails with "Permission denied (publickey)" and nothing explains
# why. Hit on heywilma-connect 2026-09-29; the same script wrote a correct line
# on three-summers-of-lincoln, so this is shell-dependent rather than reliable.
# A re-run REPLACES this repo's line: each run makes a new key and sets it as the
# GitHub secret, so keeping the old line (as this once did) broke every later deploy.
printf 'command="git-shell -c \\"git-receive-pack '"'"'%s'"'"'\\"",no-port-forwarding,no-agent-forwarding,no-pty %s\n' \
  "$BARE" "$(cat "${KEY}.pub")" \
| ssh -o BatchMode=yes "$TARGET" \
    "sudo -n sh -c 'f=/root/.ssh/authorized_keys; { grep -vF deploy-${SLUG}-ci \"\$f\"; cat; } > \"\$f.dk\" && chmod 600 \"\$f.dk\" && mv \"\$f.dk\" \"\$f\"'"

echo ">> setting GitHub secrets on ${GH_REPO}"
gh secret set DEPLOY_SSH_KEY --repo "$GH_REPO" < "$KEY"
gh secret set DROPLET_HOST --repo "$GH_REPO" --body "$DROPLET"
ssh-keyscan -t ed25519 "$DROPLET" 2>/dev/null | grep -v '^#' | gh secret set DROPLET_KNOWN_HOSTS --repo "$GH_REPO"

# The Composer credentials (ACF Pro + satis) the audit job needs, as the COMPOSER_AUTH secret:
# the same JSON as the droplet's /root/.config/composer/auth.json. Point COMPOSER_AUTH_FILE
# at a local copy to set it here; otherwise set it by hand before the first push.
if [ -n "${COMPOSER_AUTH_FILE:-}" ]; then
  gh secret set COMPOSER_AUTH --repo "$GH_REPO" < "$COMPOSER_AUTH_FILE"
  AUTH_NOTE="COMPOSER_AUTH set from ${COMPOSER_AUTH_FILE}"
else
  AUTH_NOTE="COMPOSER_AUTH NOT set — gh secret set COMPOSER_AUTH --repo ${GH_REPO} < auth.json, or the audit job fails"
fi

echo ">> writing caller workflow"
mkdir -p "$REPO_DIR/.github/workflows"
cat > "$REPO_DIR/.github/workflows/deploy.yml" <<YML
name: Deploy
# develop → staging, main → production. A known-vulnerable Composer dependency blocks the
# deploy; to ship past an advisory with no fix yet, list its ID under config.audit.ignore
# in that composer.json. Add the site's tests as a second job under needs: when it has some.
on: { push: { branches: [develop, main] } }
concurrency: deploy-\${{ github.ref_name }}
jobs:
  audit:
    runs-on: ubuntu-24.04
    env:
      COMPOSER_AUTH: \${{ secrets.COMPOSER_AUTH }}
    steps:
      - uses: actions/checkout@v5
      - uses: shivammathur/setup-php@v2
        with: { php-version: '8.4', tools: composer }
      - name: Audit every committed composer.lock
        run: git ls-files '*composer.lock' | xargs -rn1 dirname | xargs -rI{} composer audit --locked --working-dir={}

  deploy:
    needs: audit
    uses: vinnyrags/deploy-kit/.github/workflows/deploy-reusable.yml@v2
    with:
      bare_repo: ${SLUG}.git
    secrets:
      DEPLOY_SSH_KEY: \${{ secrets.DEPLOY_SSH_KEY }}
      DROPLET_HOST: \${{ secrets.DROPLET_HOST }}
      DROPLET_KNOWN_HOSTS: \${{ secrets.DROPLET_KNOWN_HOSTS }}
YML

rm -rf "$(dirname "$KEY")"
cat <<DONE

>> ONBOARDED ${SLUG}: deploy key + secrets set, caller workflow written to
   ${REPO_DIR}/.github/workflows/deploy.yml
   ${AUTH_NOTE}
   Commit + push it (needs gh 'workflow' scope) — the push itself is the first deploy.
DONE
