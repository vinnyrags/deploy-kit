---
status: active
updated: 2026-10-19
---

# Droplet cache convention — WordPress on nginx (canonical)

The standard page-caching setup for a Mythus/IX WordPress site on a DigitalOcean
droplet. Codified 2026-07-15 after a cross-property audit + deep dive concluded a
**short-TTL FastCGI microcache with no purge** is the right default for these sites
(low-to-moderate traffic marketing/portfolio sites; a 30s microcache captures the
same origin protection as long-TTL+purge exactly when traffic warrants it, without a
purge plugin, purge-coverage risk, or cached redirects).

New droplets/sites should be provisioned from this. Every production WordPress site in
the fleet matches as of 2026-10-19 (30s microcache, no nginx-helper; Redis only where
opted in). Hand-written, certbot-managed vhosts get the directives inserted into the
existing files rather than rendered from `nginx/vhost.conf.template`. Exceptions are
listed, with reasons, in the fleet-check sites file (see Enforcement).

## The baseline — what every production site gets (2026-10-19)

Written after a production site was found running with **no cache of any kind** — it
was provisioned by hand, outside this kit, and nothing checked. On a small droplet that
meant PHP workers shared with staging, scanner traffic booting full WordPress, and
multi-second stalls for visitors. The convention existed; compliance did not.

**Required on every WordPress production site we operate — no per-site decision needed:**

1. **The 30s FastCGI micro-cache plus `snippets/wp-microcache.conf`** (rules below).
2. **OPcache on** (the PHP default) and **static-asset expiry**: theme/plugin/core assets
   `expires 30d` + `immutable` (always `?ver=`-versioned); `wp-content/uploads` `expires
   30d` **without** `immutable` — uploads are not versioned, and a file replaced at the same
   URL must refresh.
3. **Origin protection, so the cache's misses don't queue behind other traffic:**
   - **Separate PHP-FPM pools for production and staging** (own socket, own
     `max_children`; staging `ondemand`). One shared pool lets a staging deploy, a test run
     or bots on staging take workers from visitors. `provision/fpm-pools.sh` (new sites get
     it from `new-site.sh`); `fpm-pools.sh --retire-default` removes `[www]` once unused.
   - **Scanner traffic rejected in nginx before PHP** — empty User-Agent, dotfiles (except
     `.well-known`), known probe paths (`/_ignition`, `*heapdump*`, `/actuator`, `/mcp`…),
     `/vendor/` (the root Composer vendor is in the docroot), and missing
     `.txt/.bak/.sql/.zip/…` answered 404 from disk. `nginx/scanner-block.snippet.conf`,
     installed by `harden.sh` and inserted with `harden.sh --scanner-block`; the vhost
     template carries it for new sites.
   - **WP-Cron on a system timer**, not page traffic (`provision/wp-cron.sh`).
   - **A PHP-FPM slow log** (`request_slowlog_timeout = 2s`) so the next "it's slow" has a
     stack trace instead of a guess. Part of every pool `fpm-pools.sh` renders.

**Opt-in, with the reason written in the site's RUNBOOK:**

- **Redis object cache** — only where significant traffic cannot be page-cached: POST /
  GraphQL, logged-in-heavy sites, WooCommerce. If staging gets it too, define
  `WP_REDIS_DATABASE` and `WP_CACHE_KEY_SALT` *before* the drop-in — the other order
  shares production's cache (it has happened).
- **Staging page cache** — yes where staging is pre-launch verification of production
  (ticketed show sites); no where staging is a content/review environment.

**Not doing:** HTML caching at the Cloudflare edge (decided 2026-10-16 — free-plan TTL
floor and a second cache to reason about). Cloudflare passes HTML through (`DYNAMIC`).

**Enforcement — the part that was missing:**

- `bin/fleet-cache-check.sh` fetches each production page twice with no query string and
  fails unless the second is a `HIT` and every page has its own body (identical bodies =
  the missing-`fastcgi_cache_key` collision). A documented `none` exception fails if a
  cache appears. The sites file is kept **outside this repo** (it maps the fleet); lines
  are `<host> <cache|none> <path>…`. Run it after any nginx change and as a periodic
  fleet check; add every new site at launch — passing it is a go-live gate.

## Known gaps in this convention (verified 2026-08-19)

Three things the rules above imply but the fleet does not actually do. None is
harmful; they're recorded so the doc isn't read as describing behavior that exists.

- **`fastcgi_cache_valid 404 5m` is inert.** WordPress emits `Cache-Control: no-cache`
  on 404s and nginx honors it, so 404s are re-generated every time. Confirmed on both
  MBF and Shucked. Caching them would need `fastcgi_ignore_headers Cache-Control
  Expires;`, which would also change 200 behaviour — so this is left alone deliberately.
- **404s never show `X-FastCGI-Cache`.** nginx's `add_header` only applies to a fixed
  success/redirect status list unless `always` is appended. So a missing header on a
  404 is expected and is *not* evidence of a misconfiguration.
- **`fastcgi_cache_key` is droplet-level, not per-site.** File 1 below lists it, but
  `nginx/wp-fastcgi-cache.conf.template` (which `new-site.sh` *appends* once per site)
  omits it — correctly, since a second copy in the same context is a duplicate-directive
  error. On every live box it sits in `nginx.conf`'s `http` block; see
  `provision/provision-base.sh`.

  > ### ⚠️ A missing `fastcgi_cache_key` does NOT fail `nginx -t`
  >
  > **This document previously claimed it did. That was wrong, and the wrong claim is what
  > let it ship.** nginx emits a *warning* and the test still passes:
  >
  > ```
  > [warn] no "fastcgi_cache_key" for "fastcgi_cache" in /etc/nginx/nginx.conf:61
  > nginx: configuration file /etc/nginx/nginx.conf test is successful
  > ```
  >
  > **Consequence when it is missing: every cached response collides on one key, and the
  > whole site serves whichever page was cached first — for every URL, including 404s.**
  > Hit `vincentragosta.io` on 2026-08-30: one file in `/var/cache/nginx/fastcgi-vinrag`
  > was serving the entire site, and `/zzq7x4-nonexistent/` returned `200` with the
  > Contact page. The four ARTHOUSE droplets were provisioned with the key and were
  > unaffected.
  >
  > **The real check — grep the warning, never trust the exit status or the success line:**
  >
  > ```bash
  > nginx -t 2>&1 | grep 'no "fastcgi_cache_key"'   # must output NOTHING
  > ```
  >
  > **Then prove it with distinct pages, and do it WITHOUT a query string.** The bypass map
  > includes `~*\?(.+)$ 1`, so any cache-buster skips the cache entirely and gives a false
  > pass — that mistake hid this fault for two days:
  >
  > ```bash
  > for p in / /contact/ /projects/; do
  >   curl -s "https://<host>$p" | grep -oE '<title>[^<]*'
  > done   # three DIFFERENT titles, and re-run so the second pass is a HIT
  > ```
  >
  > Recovery is: add the key to `nginx.conf`'s `http` block, **purge
  > `/var/cache/nginx/<zone-dir>/*`** (stale poisoned entries survive the reload
  > otherwise), then reload.

## Trap — `sites-enabled/` is the live copy, `sites-available/` is stale

On the **AVFTB and MBF droplets**, the files in `/etc/nginx/sites-enabled/` are **real
files, not symlinks**, and they have drifted from the same-named files in
`sites-available/`. Verified 2026-08-20: on both boxes the enabled copy is the newer,
correct one and the `sites-available` copy is an older revision **missing the entire
FastCGI cache block**.

Consequences, both easy to hit:

- Editing `sites-available/<domain>` changes nothing. `nginx.conf` includes only
  `sites-enabled/*`.
- "Restoring" a vhost from `sites-available` silently removes page caching. The site keeps
  serving 200s, so nothing looks broken — traffic just stops being cached.

**Always edit `sites-enabled/<domain>` directly on these boxes, and diff the two before
trusting either.** Both boxes also carry `*.bak-<epoch>` copies in `sites-available/`;
those are inert (nginx does not glob that directory) but at least one — AVFTB's
`avftb-staging.bak-1783962026` — still contains the old `fastcgi_cache_valid 200 301 302
30m`, i.e. the cached-redirect footgun. Never promote a `.bak` into `sites-enabled/`.

Sites provisioned fresh by `new-site.sh` get a proper symlink and are not affected.

## The convention (rules)

- **30s FastCGI microcache.** `fastcgi_cache_valid 200 30s;` `404 5m;` — TTL is the
  correctness floor; freshness is bounded at 30s for anonymous visitors.
- **Serve stale, lock misses** (v1.9). `include snippets/wp-microcache.conf;` in the PHP
  location: expired entries are served while one background request refreshes them, concurrent
  misses wait on a lock instead of stampeding PHP-FPM, and a PHP-FPM outage serves the last good
  page (`STALE`) for the zone's `inactive=` window. Without it a 30s cache sends a render to PHP
  every 30s per page and goes down with PHP. Opt-in per vhost; on vincentragosta.io since
  2026-10-16, proven with php-fpm stopped.
- **Never cache 3xx.** No `fastcgi_cache_valid 301 302` — a cached redirect is the
  `ERR_TOO_MANY_REDIRECTS` footgun.
- **Bypass for anyone who must see live content:** logged-in / comment / post-password
  cookies, `wp-admin` + `wp-*.php` + feeds + sitemaps, any query string, and non-GET
  methods. Editors therefore always see their changes instantly.
- **No purge-on-save.** No `nginx-helper`, no `PurgePageCache` hook — the 30s TTL makes
  purging unnecessary. (This is why Ena ships no cache hook and the Mythus cache seam
  was removed in v1.2.0.)
- **No Redis object cache by default.** WP core object cache + OPcache suffice for these
  sites; Redis object caching is a per-site opt-in only where DB queries are genuinely
  heavy (e.g. vincentragosta.io's WPGraphQL catalog). Don't run `redis-server` idle.

## File 1 — shared maps + zone: `/etc/nginx/conf.d/wp-fastcgi-cache.conf`

Put the bypass maps in a **shared conf.d include** (define once per droplet; every WP
vhost reuses them). This avoids the fragility of maps living inside one site's vhost
that other vhosts cross-reference.

```nginx
# Bypass conditions — shared by every WP vhost on this droplet.
map $request_method $no_cache_method { default 0; POST 1; PUT 1; DELETE 1; }
map $request_uri    $no_cache_uri    { default 0; ~*/wp-admin/ 1; ~*/wp-.*\.php 1; ~*/feed/ 1; ~*/sitemap.*\.xml 1; ~*\?(.+)$ 1; }
map $http_cookie    $no_cache_cookie { default 0; ~*comment_author 1; ~*wordpress_logged_in 1; ~*wp-postpass 1; }

fastcgi_cache_key "$scheme$request_method$host$request_uri";
```

Each **site** gets its own cache zone (unique dir + `keys_zone` name). Add per site to
`nginx.conf` (http block) or the conf.d include:

```nginx
fastcgi_cache_path /var/cache/nginx/fastcgi-<slug> levels=1:2 keys_zone=<SLUG>:50m inactive=60m max_size=500m use_temp_path=off;
```

## File 2 — the site vhost (`/etc/nginx/sites-available/<domain>`)

Inside `server { … }`, before the PHP location:

```nginx
    set $skip_cache 0;
    if ($no_cache_method) { set $skip_cache 1; }
    if ($no_cache_uri)    { set $skip_cache 1; }
    if ($no_cache_cookie) { set $skip_cache 1; }
```

Inside `location ~ \.php$ { … }` (after the fastcgi_pass / params):

```nginx
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache      $skip_cache;
        fastcgi_cache         <SLUG>;
        fastcgi_cache_valid   200 30s;
        fastcgi_cache_valid   404 5m;
        include               snippets/wp-microcache.conf;   # v1.9+
        add_header            X-FastCGI-Cache $upstream_cache_status;
```

Apply: `nginx -t && systemctl reload nginx`. Verify with
`curl -sD- -o/dev/null https://<domain>/ | grep -i x-fastcgi-cache` → `MISS` then `HIT`,
and `EXPIRED` ~30s later on an unchanged page.

## Migrating an existing droplet to this convention

1. **Move the maps to `conf.d`** (above) and delete the per-site/per-brand map copies
   from the vhost(s). Rename references (`$no_cache_cookie_<brand>` → `$no_cache_cookie`).
   This removes the "maps live in a staging vhost that prod cross-references" fragility.
2. Set `fastcgi_cache_valid 200 30s;` and **drop any `301 302`** from the valid list.
3. Deactivate `nginx-helper`; remove any `PurgePageCache` hook.
4. If Redis is idle (no `object-cache.php` drop-in): `systemctl disable --now redis-server`.
5. **Always back up the vhost outside `sites-enabled/`** (nginx globs that dir — a `.bak`
   there causes "duplicate listen/map" and breaks `nginx -t`). Use `/root/nginx-bak/`.
6. `nginx -t` before every reload; keep a one-line rollback (restore backup + reload).

> Live-droplet note (2026-07-15): MF/AVFTB/CBA maps have been **moved to
> `/etc/nginx/conf.d/wp-fastcgi-cache.conf`** on each droplet (out of the staging vhost —
> fragility removed). They keep their **per-brand names** (`$no_cache_*_avftb`/`_mbf`/
> `_staging`) — verbatim relocation, so zero vhost references changed; the generic names
> above are for *new* sites. Verified per droplet: anon `HIT`, logged-in cookie `BYPASS`,
> site `200`. Per-droplet rollback scripts live in `/root/nginx-bak/mapmove-*-rollback.sh`.
