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

3. **nginx cache snippets** (`nginx/`) — the canonical WP FastCGI micro-cache (200+404
   only, never 301/302) and the standard `$skip_cache` rules.

## Consume it (per site)

**GitHub side** — the site's `.github/workflows/deploy.yml`:
```yaml
name: Deploy
on: { push: { branches: [develop, main] } }
concurrency: deploy-${{ github.ref_name }}
jobs:
  deploy:
    uses: vinnyrags/deploy-kit/.github/workflows/deploy-reusable.yml@v1
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
sudo bash provision/setup-droplet.sh <site> /etc/deploy-kit/<site>.conf v1
```
The old hook is backed up to `*.bak.*`. `deploy-kit` is pinned per droplet at a tag,
so an update to this repo is a **deliberate roll** (`checkout` a new tag), never an
instant fleet-wide change. Break-glass: the backup hook (or `git push droplet`) still
works if the kit is ever unavailable.

## Fleet (reference)

| Site | Profile | PHP | Notes |
|---|---|---|---|
| View / Matchbook / Celeb Auto | `mythus-ix` | 8.4 / 8.4 / 8.3 | FastCGI micro-cache |
| vincentragosta.io, ellenharvey | `mythus-ix` | 8.4 | same recipe |
| Shucked | `classic` | 8.2 | no build, uncached |
| itzenzo.tv | `nextjs` | — | PM2/systemd |

## License

Proprietary. © Vincent Ragosta. Retained ownership; portable across projects/clients.
