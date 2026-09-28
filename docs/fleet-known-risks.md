---
status: active
updated: 2026-09-28
---

# Fleet known risks — dormant, and whose call it is to fix

Things that are wrong on droplets we are **not commissioned to work on**. None of them is
currently breaking anything. They are written down so future-us is not surprised, and so that if
one of those boxes ever does go down, the procedure already exists instead of being invented
under pressure.

## The rule first

**AVFTB, Matchbook and Celebrity Autobiography are closed, paid engagements.** Nothing is touched
on those droplets without Marc commissioning it. The only exception is a site that is actually
down or actively compromised, and even then the fix is the minimum to restore service, followed
immediately by telling Marc.

This is not a caution about technical risk. It is a commercial boundary: unrequested work on a
closed engagement is work nobody agreed to pay for, and it puts changes on a client's production
box that the client never approved.

Note also that **staging and production share one droplet** on all three. There is no such thing
as "only touching staging" there — a staging deploy reloads the php-fpm that serves production,
and an nginx edit for staging passes through the same `nginx -t` and reload.

## Risk 1 — MariaDB root has a password, so `new-site.sh` cannot run

`provision/new-site.sh` creates databases as root **over the unix socket**:

```bash
mysql <<SQL
CREATE DATABASE ...
SQL
```

On AVFTB (verified 2026-09-28) that fails:

```
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)
```

Those boxes predate `new-site.sh` and had `mysql_secure_installation` run on them, which set a
root password. There is no `/root/.my.cnf` to supply it.

**Blast radius: none today.** Existing sites connect as their own per-site DB user, not root.
Nothing is broken; the box simply cannot take a *second* site without intervention.

**If it ever needs fixing** (Marc commissions a second site on one of those boxes), the safer of
the two options is to add a credentials file rather than change how root authenticates:

```bash
# read the existing password out of the box's own notes first
printf '[client]\nuser=root\npassword=%s\n' "$PW" > /root/.my.cnf
chmod 600 /root/.my.cnf
mysql -e 'SELECT 1;'          # must succeed with no prompt
```

That is additive and reversible — `rm /root/.my.cnf` restores the previous state exactly.
Switching root to `unix_socket` auth is the better end state and matches a freshly-provisioned
box, but it is a live authentication change on a production database, and it is not worth the
risk for a dormant problem.

> **Do not run `mysql_secure_installation` on a new box.** On Ubuntu 24.04 / MariaDB 10.11 root
> already ships as `unix_socket` with `authentication_string: "invalid"` — password auth is
> *impossible* rather than merely unset, anonymous users and the `test` database are already
> absent, and MariaDB binds to `127.0.0.1`. The only thing the script changes is switching
> password auth **on**. That is how these three boxes got into this state.

## Risk 2 — `auth.json` is at a path composer never reads

Three droplets keep their ACF Pro + satis credentials at **`/root/.composer-auth.json`**.
Composer's actual home is `/root/.config/composer`, so it never reads that file on its own.

Deploys work anyway, but by luck: the deploy profile copies that file into the docroot, and
composer picks up an `auth.json` from its working directory. The profile then runs
`composer install` from **four** directories — docroot, mythus, ix, child theme — and only the
first has one.

**Blast radius: latent.** It has not bitten because the root install resolves the private
packages first and the rest hit a warm cache. A cache miss in one of the other three directories
would 401, and the hook does `git checkout -f` *before* `composer install` — so a failure leaves
new code sitting against a stale `vendor/`, which is worse than a clean failure.

**If it ever needs fixing**, this one is genuinely additive — a copy, not a change:

```bash
install -d -m 700 /root/.config/composer
cp /root/.composer-auth.json /root/.config/composer/auth.json
chmod 600 /root/.config/composer/auth.json
composer config --global home     # expect /root/.config/composer
```

Nothing is removed, so it cannot break the existing path. As of `v1.2` the `mythus-ix` profile
prefers the correct path and falls back to the legacy one, warning if neither exists — but those
boxes are pinned to `b3e057c` and will not see that until their kit is rolled.

## Risk 3 — the kit on those boxes predates several fixes

All three run deploy-kit at **`b3e057c`**, which is ten commits past tag `v1` (the AVFTB runbook
claimed `v1`; corrected 2026-09-28). That commit predates:

- `a5f626b` — installs and asserts the droplet-level `fastcgi_cache_key`
- `efbf71f` / `ff6d97a` — `deny wp-config-env.php` and `wp-config.php` in the hardening snippet
- the `v1.1` vhost template, which includes the hardening snippet so new vhosts are born hardened
- `v1.2` — the `WP_SITEURL` template fix

**Blast radius: none while they sit still.** These boxes already have a `fastcgi_cache_key` in
`nginx.conf`'s http block (verified on AVFTB and Matchbook), and their vhosts are already
hardened. The risk is only on *re-provision*: standing a new site up from `b3e057c` reproduces
bugs that are already fixed.

**Do not roll their pin as housekeeping.** `deploy/` and `.github/` are unchanged from `v1`
through `v1.2`, so a roll cannot alter deploy behaviour — but it is still an unrequested change
to a client's production box.

## Not a risk, despite appearances

- **`install_plugins: NO` for an administrator.** `DISALLOW_FILE_MODS` and `DISALLOW_FILE_EDIT`
  are set deliberately; plugins and themes come from Composer. The disabled theme editor also
  avoids the trap where a deploy's `checkout -f` silently overwrites theme-editor edits.
- **`robots.txt` not saying `Disallow: /` on a `noindex` site.** Since WP 5.3 `do_robots()` never
  emits that, by design: disallowing the crawl stops a crawler fetching the page and therefore
  ever seeing the `noindex`. The meta tag and `X-Robots-Tag` are the mechanism.
