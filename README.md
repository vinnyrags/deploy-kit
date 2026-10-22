# deploy-kit

A small, **stack-agnostic delivery layer** for git-push-to-droplet sites. It sits
*beneath* whatever a site is built with — Mythus/IX WordPress, a classic WP theme,
a Next.js app — and standardizes how code gets from a GitHub push to a live server.

> This is the **delivery** layer, orthogonal to the **runtime** platform (Mythus/IX/
> arthouse-kit). It requires nothing about the runtime; the stack-specific bits are
> config-selected **profiles**, not dependencies. Public on purpose — the workflow is
> reusable across orgs; secrets stay private in each consuming repo.

## The three pieces

1. **Reusable GitHub Actions workflow** (`.github/workflows/deploy-reusable.yml`) —
   on push to `develop`/`main`, SSHes to the droplet and pushes the ref to its bare
   repo. Each site's own workflow is a ~6-line caller.

2. **Deploy script + profiles** (`deploy/`) — runs on the droplet, invoked by a thin
   `post-receive` stub. The dispatcher (`deploy.sh`) reads a per-site config, then a
   **profile** does the stack-specific build + cache flush:
   - `mythus-ix` — Composer (root+mythus+ix+child) + npm build + FastCGI/Redis/OPcache flush
   - `classic` — no build, just a theme checkout (e.g. Shucked)
   - `nextjs` — `npm ci` + build + PM2/systemd restart (e.g. itzenzo.tv)

3. **nginx templates** (`nginx/`) — the canonical WP FastCGI micro-cache (200+404 only,
   never 301/302) as an http-context include + a per-site vhost template, plus snippets
   that `harden.sh` installs: `wp-hardening` (always included), and three opt-in per vhost —
   `wp-microcache` (serve stale on PHP failure, stampede lock), `scanner-block` (reject
   probe traffic before PHP; `harden.sh --scanner-block`) and `cloudflare-only`
   (444 for anything not via Cloudflare or loopback; proxied hosts only).

4. **Droplet provisioning** (`provision/`, `bin/`) — bring a fresh droplet to the
   canonical spec (`provision-base.sh`), stand up a site's infra (`new-site.sh`:
   DBs + web roots + bare repo + vhosts + cache + wp-config-env), and one-command
   GitHub wiring (`bin/onboard.sh`: deploy key + secrets + caller workflow). Ongoing
   ops: `backup.sh` (nightly restic → S3/B2 of DB + uploads, systemd timer, one
   `BACKUP-RESULT` line), `wp-cron.sh` (WP-Cron from a per-minute timer as the site's
   pool user) and `fpm-pools.sh` (a PHP-FPM pool per site per environment, with a slow
   log). See **[docs/new-site-runbook.md](docs/new-site-runbook.md)** for the end-to-end
   lifecycle.

   **The host standard** (what `provision-base.sh` + `new-site.sh` give a new box and site):
   TLS 1.2+, a catch-all that refuses unknown hosts, unattended patches with reboots, swap,
   ufw + fail2ban (`baseline.sh`); a key-only sudo admin with root SSH left to the CI keys
   (`ssh-admin.sh`); a PHP user and pool per environment; atomic read-only releases with
   auto-rollback; WP-Cron from timers; monitored off-site backups. `audit.sh` is the
   read-only drift check of all of it, host-wide and per site. The release history is in
   **[CHANGELOG.md](CHANGELOG.md)**.

## Consume it (per site)

**GitHub side** — the site's `.github/workflows/deploy.yml`:
```yaml
name: Deploy
on: { push: { branches: [develop, main] } }
concurrency: deploy-${{ github.ref_name }}
jobs:
  deploy:
    uses: vinnyrags/deploy-kit/.github/workflows/deploy-reusable.yml@v2   # needs the droplet kit at >= v1.5
    with:  { bare_repo: aviewfromthebridge.git }
    secrets:
      DEPLOY_SSH_KEY:      ${{ secrets.DEPLOY_SSH_KEY }}
      DROPLET_HOST:        ${{ secrets.DROPLET_HOST }}
      DROPLET_KNOWN_HOSTS: ${{ secrets.DROPLET_KNOWN_HOSTS }}
```
(Secrets are still set per-repo — the reusable workflow only centralizes the *logic*.)

**Droplet side** — `provision/new-site.sh` writes the site conf and wires the hook (see the
runbook). For a bare repo that already exists, write `/etc/deploy-kit/<site>.conf` from
`config/site.conf.example`, then:
```bash
sudo bash provision/setup-droplet.sh <site> /etc/deploy-kit/<site>.conf          # keeps the box's pin
sudo bash provision/setup-droplet.sh <site> /etc/deploy-kit/<site>.conf <tag>    # rolls it
```
The old hook is backed up to `*.bak.*`. `deploy-kit` is one checkout per droplet, pinned at a
tag, so an update to this repo is a **deliberate roll** that moves every site on that box —
never an instant fleet-wide change, and never a side effect of adding a site. Break-glass:
the backup hook (or `git push droplet`) still works if the kit is ever unavailable.

## Docs

| Doc | Covers |
|---|---|
| [docs/new-site-runbook.md](docs/new-site-runbook.md) | End-to-end lifecycle for standing up a new site |
| [docs/droplet-cache-convention.md](docs/droplet-cache-convention.md) | The caching baseline every production site gets, the canonical FastCGI micro-cache, and the `sites-enabled` drift trap. Check the fleet with `bin/fleet-cache-check.sh` |
| [docs/nginx-5xx-triage-runbook.md](docs/nginx-5xx-triage-runbook.md) | Triaging origin 5xx |
| [docs/deploy-doctrine.md](docs/deploy-doctrine.md) | Push to origin; never mutate the server |

## In production

Runs the deploys for a handful of client sites and my own, across the `mythus-ix`, `classic` and
`nextjs` profiles. Per-site details (versions, pins, known issues) are kept privately, not in this
repo.

## License

Proprietary. © Vincent Ragosta. Retained ownership; portable across projects/clients.
