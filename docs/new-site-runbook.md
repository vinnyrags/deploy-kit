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
