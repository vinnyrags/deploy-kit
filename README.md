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

   **Host baseline + drift check (v1.13).** `baseline.sh` brings a box (fresh, via
   `provision-base.sh`, or already running) to the host baseline:
   - TLS 1.2+ only, `server_tokens off`, gzip for text assets, `log_format timed`;
   - a catch-all `default_server` that refuses unknown hosts at the handshake;
   - unattended-upgrades that reboot when required and take PHP patches from the PPA;
   - a journald cap and PHP-FPM limits.

   Idempotent, backed up, and validated before any reload. `audit.sh` is the read-only
   check of the same list. It exits 1 on drift, and `test/` proves each check fails on an
   un-hardened box. Also new:
   - `backup.sh --healthchecks <conf> <env-file>`: a dead-man's switch for the nightly backup;
   - `fail2ban-direct.sh <host> --name <n>`: a scanner ban, for hosts NOT behind Cloudflare only;
   - `fpm-pools.sh --user` joins pool users to `mailrelay` when the box has one.

   **Per-pool users (v1.12, opt-in).** Separate pools stop sites competing for workers;
   they do not stop one site's PHP reading another's `wp-config-env.php`, because every
   pool runs as `www-data`. `fpm-pools.sh --user U --staging-user U` gives each pool its
   own no-login user, and `POOL_USER[branch]` in the site conf makes the rest agree: deploys
   chown to it and lock secrets to its group, and wp-cron and the smoke test run as it. The
   smoke test must run as the pool user, or it cannot read the env file and passes as
   "not installed, skipped". Mail: `MAIL_GROUP` / `MAIL_TEST_USER` for `mail.sh`, so a
   shared relay config stays readable by every pool that sends. Without `POOL_USER`,
   everything stays `www-data`, exactly as before. Releases can also link per-branch
   extra paths from `shared/` (`SHARED_EXTRA`, e.g. a Redis drop-in). `backup.sh` resolves
   a symlinked uploads dir first, because restic stores a symlink as a symlink.

   **In-place → releases migration (v1.14).** `migrate-to-releases.sh` moves one branch
   of a live site onto `LAYOUT=releases`. `--prepare` builds `shared/` and the first
   release while nginx still serves the old docroot; `--switch` is the one live moment
   (final rsync, vhost to `<base>/current`, conf installed, smoke test that rolls back on
   failure); `--rollback` restores the vhost and conf. The old docroot is never touched.

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

**Droplet side** — write the site config, then wire the hook:
```bash
# 1. cp config/site.conf.example -> /etc/deploy-kit/<site>.conf and edit
# 2. install kit + wire the bare repo's post-receive:
sudo bash provision/setup-droplet.sh <site> /etc/deploy-kit/<site>.conf v1.8
```
The old hook is backed up to `*.bak.*`. `deploy-kit` is pinned per droplet at a tag,
so an update to this repo is a **deliberate roll** (`checkout` a new tag), never an
instant fleet-wide change. Break-glass: the backup hook (or `git push droplet`) still
works if the kit is ever unavailable.

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
