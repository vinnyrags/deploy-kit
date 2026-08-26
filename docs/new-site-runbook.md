# New ARTHOUSE site — end-to-end runbook

The ordered lifecycle for standing up a new Mythus/IX WordPress site, from nothing to
live. Three layers: **code** (runtime), **droplet** (infra), **delivery** (this kit).

> Status: laid out, **not yet battle-tested** — the first real site is the acceptance
> test; fix templates as issues surface (worst case is an `nginx -t` failure).

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
# on a fresh Ubuntu 24.04 droplet, as root:
curl -fsSL https://raw.githubusercontent.com/vinnyrags/deploy-kit/main/provision/provision-base.sh | bash -s 8.4
mysql_secure_installation      # set the MariaDB root password
```
Installs nginx + php-fpm + mariadb + node + composer + wp-cli, the cache dir + drop-default
vhost, and deploy-kit at `/opt/deploy-kit`.

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

## 4. DNS + TLS
- Point Cloudflare records (apex, `www`, `staging.`) at the droplet.
- `certbot --nginx -d <domain> -d www.<domain>` and `certbot --nginx -d staging.<domain>`
  — or **DNS-01 pre-issue** for a no-TLS-gap cutover (see the Shucked engagement).

## 5. Go live
- **First deploy:** push `develop` (→ staging) then `main` (→ prod). Code lands + builds
  via the kit hook.
- **`wp core install`** (fresh) or import the DB.
- Verify: staging + prod 200, `X-FastCGI-Cache` header present, deploy log clean.

## Conventions (new sites)
- Staging = `staging.<domain>` at `/var/www/staging.<domain>/public`.
- Cache: zone `<SLUG>` / dir `fastcgi-<slug>` (+ `-staging`); skip-maps suffix `<slug>`.
- DBs: `<slug>_prod` / `<slug>_stg`. Bare repo: `/var/repo/<slug>.git`.
- Default profile `mythus-ix`, `REDIS=0` (FastCGI page cache only, matching View/MBF/CA).
