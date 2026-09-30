# New ARTHOUSE site — end-to-end runbook

The ordered lifecycle for standing up a new Mythus/IX WordPress site, from nothing to
live. Three layers: **code** (runtime), **droplet** (infra), **delivery** (this kit).

> Status: **battle-tested once.** 3 Summers of Lincoln was provisioned end-to-end with this
> runbook on 2026-09-28 (droplet `3sol-prod-01`, kit `v1.1`) with no template failures. The
> corrections that run surfaced are folded in below — most importantly step 1's MariaDB note.

## 0. Code (your Mac) — the runtime
1. Scaffold a child theme from **Ena** (`bin/rename`), wire `composer.json` to satis +
   ACF (auth.json), require `mythus` / `ix` / `arthouse-kit`.
2. `git init`, create the GitHub repo (`arthousenewyork/<name>` or `vinnyrags/<name>`),
   `main` + `develop`. First `npm run build`.
   *(Runtime setup is unchanged by this kit; see the mythus/ix docs.)*

> **The satis registry needs credentials, since 2026-08-26.** `packages.vincentragosta.io`
> is HTTP basic auth (`auth_basic`, htpasswd at `/etc/nginx/.htpasswd-satis` on the
> vincentragosta.io droplet). Every consumer needs a `packages.vincentragosta.io` entry in
> its `auth.json` alongside the ACF Pro one:
>
> ```json
> "http-basic": {
>     "connect.advancedcustomfields.com": { "username": "...", "password": "..." },
>     "packages.vincentragosta.io":       { "username": "composer", "password": "..." }
> }
> ```
>
> **Put it in place BEFORE the first deploy.** The hook does `git checkout -f` and *then*
> `composer install`; if composer 401s, the site is left with new code against a stale
> `vendor/`, which is worse than a clean failure.
>
> On the droplet it must live at **`/root/.config/composer/auth.json`** — composer's actual
> home. Three ARTHOUSE droplets carried the credentials at `/root/.composer-auth.json`, a
> non-standard name composer never reads; deploys only worked because a copy also sat in each
> docroot, and composer picks up an `auth.json` from its working directory. That worked by
> luck: `deploy/profiles/mythus-ix.sh` runs `composer install` from **four** directories
> (docroot, mythus, ix, child theme), and only the first has one. Verify with:
>
> ```bash
> composer config --global home        # expect /root/.config/composer
> ```
>
> The password is recoverable from any droplet's `auth.json` if lost. Rotating it means
> `htpasswd -B /etc/nginx/.htpasswd-satis composer` plus every `auth.json` in the fleet.

## 1. Droplet — base (once per box)
```bash
# on a fresh Ubuntu 24.04 droplet, as root. Pin the ref — do not track main:
DEPLOY_KIT_REF=v1.5 bash -c 'curl -fsSL https://raw.githubusercontent.com/vinnyrags/deploy-kit/v1.5/provision/provision-base.sh | bash -s 8.4'
```
Installs nginx + php-fpm + mariadb + node + composer + wp-cli, the cache dir + drop-default
vhost, the droplet-level `fastcgi_cache_key`, `harden.sh`, and deploy-kit at `/opt/deploy-kit`.

> **Do NOT run `mysql_secure_installation`.** Earlier revisions of this runbook told you to, to
> "set the MariaDB root password". That advice is wrong on Ubuntu 24.04 / MariaDB 10.11 and it is
> actively harmful:
>
> - Root already ships as `unix_socket` with `authentication_string: "invalid"` — password auth is
>   **impossible**, not merely unset. Verify with
>   `mysql -N -e 'SELECT User,Host,JSON_DETAILED(Priv) FROM mysql.global_priv WHERE User="root";'`
>   and prove the boundary with `sudo -u www-data mysql -uroot -e 'SELECT 1;'` (want *Access denied*).
> - Anonymous users and the `test` database are already absent; MariaDB binds to `127.0.0.1`. The
>   only thing the script would change is **switching password auth on**, which is a downgrade.
> - `new-site.sh` creates databases as root **over the socket**. Setting a root password breaks it
>   unless you also add a `/root/.my.cnf`. The AVFTB droplet has a root password and no `.my.cnf`,
>   which is exactly why `new-site.sh` would fail on that box today.
>
> Add a swapfile instead, which the base script does not do and every fleet box has:
> `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
> plus an `/etc/fstab` line.

## 2. Droplet — the site's infra
```bash
/opt/deploy-kit/provision/new-site.sh <slug> <prod_domain> 8.4
# e.g. new-site.sh aviewfromthebridge viewfromthebridgeplay.com 8.4
```
Creates prod+staging DBs, web roots, bare repo + hook + `site.conf`, the two nginx
vhosts + FastCGI cache blocks, and per-env `wp-config-env.php` (with generated DB creds).

## 3. Delivery — wire GitHub → droplet
```bash
# on your Mac:
deploy-kit/bin/onboard.sh <repo_dir> <gh_repo> <droplet_ip> <slug>
```
Sets the dedicated deploy key (forced-command), the three GitHub secrets, and writes the
caller workflow. Commit + push it (needs gh `workflow` scope).

## 4. DNS + TLS — issue BEFORE you point DNS
The vhost template listens on **port 80 only**; certbot adds the 443 block. If the zone's SSL mode
is Full or Full (strict) — it should be — then pointing proxied records at a droplet with no 443
listener gives every visitor a **521** until certbot finishes. Pre-issue over DNS-01 and there is
no gap at all, and no window where the raw origin IP sits in public DNS:

```bash
apt-get install -y python3-certbot-dns-cloudflare
install -d -m 700 /root/.secrets
printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /root/.secrets/cloudflare.ini
chmod 600 /root/.secrets/cloudflare.ini

certbot certonly --non-interactive --agree-tos -m <email> \
  --authenticator dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 -d <domain> -d www.<domain>
certbot install --nginx --cert-name <domain> --non-interactive --redirect
```
The token needs `Zone:DNS:Edit` (to write `_acme-challenge`) and `Zone:Zone Settings:Edit` (for ECH,
below). *Then* add the proxied A records for apex, `www` and `staging.`.

**Re-run `harden.sh --check` after certbot.** Certbot rewrites the vhosts; confirm the hardening
snippet and the `fastcgi_cache` directive both survived before you call it done.

**Check ECH on a new zone — it is ON by default for Free zones.** `dig @1.1.1.1 <domain> TYPE65
+short` is the authority, not the API response or the dashboard. See
[cloudflare-edge-settings.md](cloudflare-edge-settings.md).

Once the origin has a real cert, move the zone from Full to **Full (strict)** — plain Full accepts
any origin cert, including self-signed.

## 5. Go live
- **First deploy:** push `develop` (→ staging) then `main` (→ prod). Code lands + builds
  via the kit hook.
- **`wp core install`** (fresh) or import the DB.
- Verify: staging + prod 200, `X-FastCGI-Cache` header present, deploy log clean.
- **Password-gated site?** Set `GATED=1` in `/etc/deploy-kit/<slug>.conf`. Without it the
  smoke test and `verify-site.sh` read the gate's 401 as a broken site; with it they expect
  the 401, assert the gate is never served from cache, and probe the cache on `/robots.txt`
  instead of the homepage (so the gate must let `robots.txt` through).
- **CI only goes red on a failed deploy with workflow `@v2` + droplet kit ≥ `v1.5`.** git
  ignores the post-receive hook's exit status, so on `@v1` a failed build or smoke test still
  shows a green run. New sites should call `deploy-reusable.yml@v2`.

## Conventions (new sites)
- Staging = `staging.<domain>` at `/var/www/staging.<domain>/public`.
- Cache: zone `<SLUG>` / dir `fastcgi-<slug>` (+ `-staging`); skip-maps suffix `<slug>`.
- DBs: `<slug>_prod` / `<slug>_stg`. Bare repo: `/var/repo/<slug>.git`.
- Default profile `mythus-ix`, `REDIS=0` (FastCGI page cache only, matching View/MBF/CA).

## Deferred platform candidates — read before building the next site

Things that came up on 3 Summers of Lincoln (launched 2026-09-30) and were judged **not yet
worth lifting into the platform**. Each is solved inside 3SOL's child theme today. If the next
site needs one, lift it then, from 3SOL's version, rather than rebuilding it.

- **Site-wide password gate → arthouse-kit.** `three-summers-of-lincoln`
  `src/Providers/Gate/GateProvider.php`. Deferred because 3SOL is the only gated site. It
  carries three launch-day fixes a rebuild would likely miss: it closes the REST API to
  anonymous callers (the gate itself lets JSON requests through), it sends `no-store` on every
  page served past the gate (otherwise the FastCGI cache hands the first unlocked page to every
  anonymous visitor), and it lets `robots.txt` through. Lift it when a second gated site
  appears — and set `GATED=1` in that site's conf.
- **WebP sub-sizes → IX.** 3SOL's `ThemeProvider::webpSubSizes()` maps PNG/JPEG → WebP via
  `image_editor_output_format`. Cut the gate's hero from ~12 MB to under 1 MB. Deferred
  because on an existing site it only helps new uploads, and regenerating old ones converts the
  *full-size* file too, which drops the srcset from any block still pointing at the old
  `.png`/`.jpg` until the markup is repointed (3SOL RUNBOOK trap 26). Cheap to adopt on a
  **new** site from day one; costly to retrofit.
- **Editor stylesheet cache-busting → IX.** 3SOL's `ThemeProvider::versionEditorStyles()`
  appends `filemtime` to `add_editor_style()` URLs, which TinyMCE otherwise versions only by
  its own release — a year of staleness behind `immutable`. Open on every other Mythus/IX site
  behind a CDN; lifting it is a satis release plus a composer update per site.
- **Per-site extra no-cache cookies in the cache-map template → not planned.** Considered for
  the gate's cookie and rejected: the app that varies a response should mark it `no-store`, and
  `verify-site.sh` now fails if `fastcgi_ignore_headers` would stop nginx honoring that.
