# Changelog

What each release added, newest first. Per-droplet pins are kept privately, not here.

## v1.19.0 — new sites start on the standard
- `new-site.sh` builds every site on releases under `/srv/<host>/` with a pool user per
  environment, fresh salts in the env file, and WP-Cron timers. It no longer re-pins the
  droplet's kit, checks MariaDB access before creating anything, and takes
  `MYSQL_DEFAULTS_FILE` for a root with a password.
- `setup-droplet.sh` without a ref leaves the kit where it is pinned (was: `v1`).
  `provision-base.sh` pins the latest release tag when `DEPLOY_KIT_REF` is unset (was: `main`)
  and no longer says to run `mysql_secure_installation`.
- A first release deploys before `wp core install` (`wp_state` tells an empty database from
  a broken one). The smoke test now fails when WordPress cannot load as the pool user,
  where it used to skip. `wp-cron.sh --run` is a no-op until WordPress is installed.
- `baseline.sh`: 2 GB swap + `vm.swappiness=10` (`--swap`), and it no longer adds an
  allow-from-anywhere web rule to a ufw that already restricts 80/443.
- `audit.sh`: `os.swap`, and per-site checks from each conf — `site.backup` (FAIL for a
  production site without a backup timer), `site.cron`, `site.layout`.
- `onboard.sh` installs the deploy key through a sudo admin (`[ssh_target]`), so it works
  after `--lock-root`; a re-run replaces the key instead of keeping a stale one; and the
  workflow it writes gates the deploy on `composer audit --locked` (`COMPOSER_AUTH_FILE`).
- `verify-site.sh` reads each environment's docroot and pool user from the site conf.
- **Smoke test fix (affects every earlier version):** it read `home` through WP-CLI with the
  theme loaded, so a fatal in the theme made it log "could not resolve home_url, skipped" and
  pass — a 500 left live behind a green deploy and no rollback. It now reads `home` with
  `--skip-themes --skip-plugins`, and an installed site whose home cannot be read fails.
  Found on the v1.19 rehearsal droplet.
- `new-site.sh` retires the distro's `[www]` pool once nothing uses it.

## v1.18 — Next.js on releases
`LAYOUT[b]=releases` now works for `nextjs`: each
deploy builds in `releases/<stamp>` as the app user while the live one keeps serving;
`shared/.env.production` is linked in; the release is root-owned except `.next/` (ISR +
image cache), and `node_modules` stays. Switch, restart, localhost smoke test, switch back
on failure, `rollback.sh`. `releases.sh` gained profile hooks (`profile_user`, `_finalize`,
`_check`, `_smoke`, `_after`) whose defaults are the WordPress behavior.

## v1.16 — Next.js without root
`node.sh --major 24` installs system Node from
NodeSource's signed repo and lets unattended-upgrades patch it. `nextjs-service.sh <unit>
--user U --dir D --port P` writes a hardened systemd unit (only `D/.next` writable, no
`/home`, read-only system) and the no-login user. The `nextjs` profile takes per-branch
`APP_USER`, `SYSTEMD_UNIT`, `PORT`, `SITE_URL`, `POST_DEPLOY`: it builds as the app user,
locks `.env*` to `640 root:<user>`, stops before restarting if the build fails, and
smoke-tests `127.0.0.1:PORT`. `audit.sh` adds `os.noderoot`. Without `APP_USER`, the old
root build and `PM2_APP` still work.

## v1.15 — Admin user + SSH settings
`ssh-admin.sh --user <name> --key <file>`
adds a key-only sudo user (NOPASSWD, so `ssh <host> sudo …` stays scriptable);
`--no-x11` turns X11 forwarding off; `--lock-root` sets `PermitRootLogin
forced-commands-only`, so only the CI deploy keys still reach root. It refuses until a
sudo user has a key, and lists the root keys that will stop working. Settings live in
`sshd_config.d/10-deploy-kit.conf`, and `sshd -t` must pass or the old file returns.
`audit.sh` adds `sec.admin` and `sec.x11`.

## v1.14 — In-place → releases migration
`migrate-to-releases.sh` moves one branch
of a live site onto `LAYOUT=releases`. `--prepare` builds `shared/` and the first
release while nginx still serves the old docroot; `--switch` is the one live moment
(final rsync, vhost to `<base>/current`, conf installed, smoke test that rolls back on
failure); `--rollback` restores the vhost and conf. The old docroot is never touched.

## v1.13 — Host baseline + drift check
`baseline.sh` brings a box (fresh, via
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

## v1.12 — Per-pool users
Separate pools stop sites competing for workers;
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
