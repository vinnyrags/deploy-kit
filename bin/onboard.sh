#!/bin/bash
# deploy-kit — one-command onboarding of a repo into the deploy pipeline. Run from
# your Mac. Folds together the per-site delivery wiring: a dedicated deploy key,
# the forced-command authorized_keys line on the droplet, the three GitHub secrets,
# and the caller workflow in the repo. (The droplet-side infra + hook are done by
# provision/new-site.sh.)
#
#   Usage:  onboard.sh <repo_dir> <gh_repo> <droplet_ip> <bare_slug>
#     repo_dir     local checkout, e.g. ~/Projects/.../aviewfromthebridge
#     gh_repo      e.g. arthousenewyork/a-view-from-the-bridge
#     droplet_ip   e.g. 104.248.234.176
#     bare_slug    /var/repo/<slug>.git on the droplet, e.g. aviewfromthebridge
#
# Requires: gh (authed, with `workflow` scope), ssh access to root@droplet.
set -euo pipefail
REPO_DIR="${1:?repo dir}"; GH_REPO="${2:?gh repo}"; DROPLET="${3:?droplet ip}"; SLUG="${4:?bare slug}"
KEY="$(mktemp -d)/deploy-${SLUG}"
BARE="/var/repo/${SLUG}.git"

echo ">> generating deploy key"
ssh-keygen -t ed25519 -f "$KEY" -N "" -C "deploy-${SLUG}-ci" -q

echo ">> installing forced-command key on ${DROPLET} (git-receive-pack only, one repo)"
# The key line is built here and sent as STDIN DATA, never interpolated into the
# remote command string. Passing it as an argument means the remote shell
# re-parses the escaped quotes, and it can silently swallow the command="..."
# prefix — leaving a line that still contains the key and the comment, so a grep
# for the comment finds it, but with no forced command and a broken first field.
# The push then fails with "Permission denied (publickey)" and nothing explains
# why. Hit on heywilma-connect 2026-09-29; the same script wrote a correct line
# on three-summers-of-lincoln, so this is shell-dependent rather than reliable.
printf 'command="git-shell -c \\"git-receive-pack '"'"'%s'"'"'\\"",no-port-forwarding,no-agent-forwarding,no-pty %s\n' \
  "$BARE" "$(cat "${KEY}.pub")" \
| ssh -o BatchMode=yes "root@${DROPLET}" \
    "grep -qF 'deploy-${SLUG}-ci' ~/.ssh/authorized_keys && cat >/dev/null || cat >> ~/.ssh/authorized_keys"

echo ">> setting GitHub secrets on ${GH_REPO}"
gh secret set DEPLOY_SSH_KEY --repo "$GH_REPO" < "$KEY"
gh secret set DROPLET_HOST --repo "$GH_REPO" --body "$DROPLET"
ssh-keyscan -t ed25519 "$DROPLET" 2>/dev/null | grep -v '^#' | gh secret set DROPLET_KNOWN_HOSTS --repo "$GH_REPO"

echo ">> writing caller workflow"
mkdir -p "$REPO_DIR/.github/workflows"
cat > "$REPO_DIR/.github/workflows/deploy.yml" <<YML
name: Deploy
on: { push: { branches: [develop, main] } }
concurrency: deploy-\${{ github.ref_name }}
jobs:
  deploy:
    uses: vinnyrags/deploy-kit/.github/workflows/deploy-reusable.yml@v1
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
   Commit + push it (needs gh 'workflow' scope) — the push itself is the first deploy.
DONE
