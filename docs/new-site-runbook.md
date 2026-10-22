# New site — 0 to 100 in one sitting

The ordered steps for a new Mythus/IX WordPress site, from an empty droplet to a launched
site on the standard vincentragosta.io runs: own PHP user per environment, atomic read-only
releases, deploys only through GitHub Actions, root SSH for CI only, baseline + drift audit,
monitored off-site backups. Each step names the script that does it. **(manual)** marks the
steps no script can do.

> Status: rehearsed end to end on a throwaway droplet on 2026-10-22 (kit v1.19): base, admin
> user, `new-site.sh`, first deploys before install, install, rollback of a broken release,
> `verify-site.sh` 22/0, audit (only `site.backup` failing, as designed), root lock and
> `onboard.sh` through the admin user. Not covered: TLS, Cloudflare and backups, which need a
> real domain and credentials.

## Before the droplet — the code (your Mac)
1. Scaffold the child theme from **Ena** (`bin/rename`); wire `composer.json` to satis + ACF;
   require `mythus` / `ix` / `arthouse-kit`. `wp-config.php` requires `wp-config-env.php`
   **above** its guarded placeholder salts.
2. `git init`, create the GitHub repo, push `main` + `develop`. First `npm run build`.

## 1. Droplet base — once per box
1. **(manual)** Create the droplet (Ubuntu 24.04), add your SSH key, turn on DigitalOcean
   backups.
2. As root, pinned to a release tag (never `main`):
   ```bash
   curl -fsSL https://raw.githubusercontent.com/vinnyrags/deploy-kit/<tag>/provision/provision-base.sh \
     | DEPLOY_KIT_REF=<tag> bash -s 8.4
   ```
   nginx, PHP-FPM, MariaDB, system Node, Composer, wp-cli, the cache key, `harden.sh`, and
   `baseline.sh`: TLS 1.2+, catch-all, auto-reboot patches, journald cap, 2 GB swap, ufw +
   fail2ban. It ends by printing `audit.sh`.
   **Do not run `mysql_secure_installation`**: root is already socket-only and the script
   would only turn password auth on, which breaks `new-site.sh`.
3. Admin user, from a second terminal you keep open:
   ```bash
   bash /opt/deploy-kit/provision/ssh-admin.sh --user <admin> --key /root/<admin>.pub --no-x11
   ssh <admin>@<ip> sudo true        # prove it before anything else
   ```
   Do **not** `--lock-root` yet; step 3.2 needs root once more on a bare box.
4. **(manual)** Satis + ACF credentials at **`/root/.config/composer/auth.json`** (both
   `http-basic` entries), before the first deploy: the hook builds after checkout, and a 401
   leaves new code on a stale `vendor/`. `composer config --global home` must print
   `/root/.config/composer`.
5. Outbound mail, if the site sends any: `provision/mail.sh` (DigitalOcean blocks 25/465/587;
   use 2587).

## 2. The site's infrastructure
```bash
bash /opt/deploy-kit/provision/new-site.sh <slug> <domain> 8.4 [theme] [--user <name>] [--max N]
```
Creates, and refuses if any of it already exists:
- pool users `<slug>` and `<slug>-stg`, each with its own PHP-FPM pool and slow log;
- `/srv/<domain>/` and `/srv/staging.<domain>/` with `releases/` and `shared/` (uploads,
  debug.log, and `wp-config-env.php` with fresh DB credentials and salts, `640 root:<user>`);
- both databases, the bare repo + hook, `/etc/deploy-kit/<slug>.conf` with
  `LAYOUT=releases` and `POOL_USER`, the vhosts on `<base>/current` with `$realpath_root`,
  the FastCGI cache blocks;
- WP-Cron timers for both branches (`DISABLE_WP_CRON` is already in the env file).

It leaves the kit pinned where it is. On a box whose MariaDB root has a password,
pass `MYSQL_DEFAULTS_FILE=<0600 file with [client] user=root password=…>`.

## 3. Delivery — GitHub to the droplet (your Mac)
1. ```bash
   COMPOSER_AUTH_FILE=<local copy of auth.json> \
     deploy-kit/bin/onboard.sh <repo_dir> <gh_repo> <droplet_ip> <slug> [ssh_target]
   ```
   Deploy key (forced to `git-receive-pack` on this one repo), the GitHub secrets, and a
   `deploy.yml` whose `audit` job (`composer audit --locked` on every committed lock)
   gates the deploy. `ssh_target` is how you reach the box: `root@<ip>` on a fresh box, or
   the admin user once root is locked. A re-run replaces the key; it never stacks them.
2. Lock root: `sudo bash /opt/deploy-kit/provision/ssh-admin.sh --lock-root`. Root now takes
   only the CI keys.

## 4. DNS and TLS — issue before you point DNS
The vhosts listen on 80 only; with the zone on Full (strict), proxied records pointed at a
box with no 443 listener return 521 until certbot finishes. Pre-issue over DNS-01:
```bash
apt-get install -y python3-certbot-dns-cloudflare
install -d -m 700 /root/.secrets
printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /root/.secrets/cloudflare.ini && chmod 600 /root/.secrets/cloudflare.ini
certbot certonly --non-interactive --agree-tos -m <email> --authenticator dns-cloudflare \
  --dns-cloudflare-credentials /root/.secrets/cloudflare.ini --dns-cloudflare-propagation-seconds 30 \
  -d <domain> -d www.<domain> -d staging.<domain>
certbot install --nginx --cert-name <domain> --non-interactive --redirect
```
Token scopes: `Zone:DNS:Edit` and `Zone:Zone Settings:Edit`. Then, **(manual)** in Cloudflare:
- proxied A records for apex, `www`, `staging`;
- SSL mode **Full (strict)**;
- **Minimum TLS 1.2** (Edge Certificates; it defaults to 1.0);
- ECH off. Check with `dig @1.1.1.1 <domain> TYPE65 +short`, which is authoritative where the
  API and the dashboard are not.

Re-run `harden.sh --check` after certbot: it rewrites the vhosts.

Optional and one-way: `include snippets/cloudflare-only.conf;` after the hardening include
makes the origin answer only Cloudflare. Never on the box that serves the private
Composer registry: it is DNS-only, and every deploy fetches from it.

## 5. First deploy and install
1. Push `develop`, then `main`. Each push builds a release while nothing changes for
   visitors, then switches. Before `wp core install` the pre-switch check confirms only that
   core is present.
2. Install as the pool user, from the release (code is read-only; this only writes the DB):
   ```bash
   cd /srv/staging.<domain>/current && sudo -u <slug>-stg wp --path=wp core install …
   ```
   **(manual)** Set `admin_email` to your own address — not the scaffold's
   default, and not the client's.
3. **Password-gated site?** Set `GATED=1` in the conf. The smoke test and `verify-site.sh`
   then expect the gate's 401 and probe the cache on `/robots.txt`.

## 6. Backups — before launch, not after
```bash
bash /opt/deploy-kit/provision/backup.sh --install /etc/deploy-kit/<slug>.conf
# (manual) /root/.restic-env (0600): repository + B2 key; the restic password ALSO in your password manager
bash /opt/deploy-kit/provision/backup.sh --init /etc/deploy-kit/<slug>.conf
bash /opt/deploy-kit/provision/backup.sh --run  /etc/deploy-kit/<slug>.conf
bash /opt/deploy-kit/provision/backup.sh --healthchecks /etc/deploy-kit/<slug>.conf /root/.hc-<slug>.env
```
`audit.sh` FAILs `site.backup` for any production site without its timer, so this step
cannot be skipped silently.

## 7. Verify — the step that decides whether it worked
```bash
bash /opt/deploy-kit/provision/verify-site.sh <slug> <domain> --env both   # exit 0
sudo bash /opt/deploy-kit/provision/audit.sh                                # 0 fail
```
Then add the site to `~/.claude/ops/fleet-cache.sites` and run `bin/fleet-cache-check.sh`
(the launch gate: it compares page bodies twice, with no query string).

## Conventions
- Staging is `staging.<domain>`. Releases at `/srv/<host>/current`, state in `/srv/<host>/shared`.
- Pool users `<slug>` / `<slug>-stg`. DBs `<slug>_prod` / `<slug>_stg`. Bare repo `/var/repo/<slug>.git`.
- Cache zone `<SLUG>` / dir `fastcgi-<slug>` (+ `-staging`); skip-map suffix `<slug>`.
- Profile `mythus-ix`, `REDIS=0` (FastCGI page cache only).
- The kit is one checkout per droplet. Roll the pin deliberately (`setup-droplet.sh <slug>
  <conf> <tag>` moves every site on the box), never as a side effect.

## Deferred platform candidates — read before building the next site

Things that came up on 3 Summers of Lincoln (launched 2026-09-30) and were judged **not yet
worth lifting into the platform**. Each is solved inside 3SOL's child theme today. If the next
site needs one, lift it then, from 3SOL's version, rather than rebuilding it.

- **Site-wide password gate → arthouse-kit.** `three-summers-of-lincoln`
  `src/Providers/Gate/GateProvider.php`. It carries three launch-day fixes a rebuild would
  likely miss: it closes the REST API to anonymous callers, sends `no-store` on every page
  served past the gate (otherwise the FastCGI cache hands the first unlocked page to every
  anonymous visitor), and lets `robots.txt` through. Set `GATED=1` in that site's conf.
- **WebP sub-sizes → IX.** 3SOL's `ThemeProvider::webpSubSizes()` maps PNG/JPEG → WebP via
  `image_editor_output_format`. Cheap to adopt on a **new** site from day one; costly to
  retrofit (regenerating old uploads converts the full-size file and breaks srcsets still
  pointing at the old `.png`/`.jpg`).
- **Editor stylesheet cache-busting → IX.** 3SOL's `ThemeProvider::versionEditorStyles()`
  appends `filemtime` to `add_editor_style()` URLs, which TinyMCE otherwise versions only by
  its own release. Open on every other Mythus/IX site behind a CDN.
- **Per-site extra no-cache cookies in the cache-map template → not planned.** The app that
  varies a response should mark it `no-store`; `verify-site.sh` fails if
  `fastcgi_ignore_headers` would stop nginx honoring that.
