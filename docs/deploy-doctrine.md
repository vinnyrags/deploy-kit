# Deploy doctrine — push to origin, never mutate the server

The one rule: **changes reach a site by being committed and pushed to `origin`.**
Nothing is edited into place on the droplet.

This exists because both site runbooks got it wrong in the same direction, and
because following the wrong path on 2026-08-24 armed a silent regression that
would have reverted a security fix on the next deploy.

## The path

```
edit locally  →  commit  →  push origin develop  →  staging deploys  →  verify
              →  merge to main  →  push origin main  →  production deploys  →  verify
```

`.github/workflows/deploy.yml` in each site is a thin caller into
`deploy-kit/.github/workflows/deploy-reusable.yml@v1`. That workflow adds a
`droplet` remote and pushes the ref to the bare repo under `/var/repo`. The
droplet's post-receive hook then runs `deploy-kit/deploy/deploy.sh`, which does
the stack-specific build and cache flush.

`develop` → staging. `main` → production. Both branches deploy. There is a
`concurrency: deploy-${{ github.ref_name }}` guard so two pushes to the same
branch cannot race.

### Both runbooks used to deny this

- Matchbook's said *"Pushing to `origin` (GitHub) deploys nothing."*
- Celebrity Autobiography's filed `git push origin develop main` under
  *"backup / collaboration"*.

Both were wrong. On 2026-08-24 two pushes to `origin main` deployed to
production on both sites. If a runbook still says otherwise, the runbook is
stale — this file is the source of truth.

## `git push droplet` is the fallback, not the path

`git push droplet <branch>` reaches the same bare repo and runs the same hook,
so it works. Prefer `origin` anyway:

- it leaves an audit trail in Actions someone else can read
- the concurrency guard prevents racing deploys
- it cannot deploy a commit that is not on GitHub, so the repo can never be
  behind what is running

Use `droplet` only when GitHub or Actions is unavailable, and push to `origin`
afterwards so the two agree.

## Never run composer, or edit tracked files, on the server

The post-receive hook does `git checkout -f` followed by `composer install`
**from the committed lock file**. So anything changed on the droplet that git
tracks is either overwritten on the next deploy, or — worse — silently reverted
while looking fine until someone checks.

### The trap this rule was written for

On 2026-08-24, IX was upgraded to v1.7.0 (a security fix closing username
enumeration) by running `composer update vincentragosta/ix -W` **in the child
theme directory on the droplet**. The sites were verified working. But the
`composer.lock` committed in each repo still pinned v1.6.0, and that lock is
what `composer install` reads.

The next deploy to either site would have reinstalled v1.6.0 and quietly
reopened the hole. Nothing would have broken. No error, no failed build — the
sites would simply have gone back to publishing their admin usernames.

It was caught and back-filled into git the same night, but the correct order was
never to do it that way:

```bash
# correct — lock is generated locally and committed, the server only installs it
cd wp-content/themes/<child>
composer update vincentragosta/ix -W
git add composer.lock && git commit && git push origin develop
```

**Note which directory.** IX's PHP classes autoload from the *child theme's*
`vendor/vincentragosta/ix` (pulled in transitively by arthouse-kit), not from
`themes/ix`. Updating the root composer changes the build-script copy and does
nothing to the classes that actually run. See the two-ix-copies trap in the
site runbooks.

### What is legitimately server-side

Untracked by design, and safe to change on the droplet:

- `wp-config-env.php` — DB credentials and salts, gitignored per environment
- `wp-content/uploads/` — the media library
- the database — content, options, users
- `/etc/deploy-kit/<site>.conf`, nginx vhosts, TLS certs

Everything else lives in git.

## Verifying a deploy actually landed

Two things routinely produce a false negative, and both bit on 2026-08-24:

**The FastCGI micro-cache.** Sites cache 200s for 30s. Verifying immediately
after a deploy can return the pre-deploy response and look like the change
failed. Either purge the site's cache dir (see
`droplet-cache-convention.md`), wait out the window, or check the
`X-FastCGI-Cache` response header — `BYPASS` means you are seeing live output.

**OPcache.** `validate_timestamps` is on with a 2s revalidate, so a normal
deploy self-heals as composer rewrites mtimes. If you genuinely need a hard
clear, restart the site's php-fpm pool — note that hits the shared
staging+prod pool on single-droplet sites. CLI `opcache_reset()` does *not*
touch the php-fpm cache.

Verify from outside with a cache-busting query string, against the behaviour
that matters, not against a file on disk.
