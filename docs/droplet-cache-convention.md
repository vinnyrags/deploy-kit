---
status: active
updated: 2026-08-13
---

# Droplet cache convention — WordPress on nginx (canonical)

The standard page-caching setup for a Mythus/IX WordPress site on a DigitalOcean
droplet. Codified 2026-07-15 after a cross-property audit + deep dive concluded a
**short-TTL FastCGI microcache with no purge** is the right default for these sites
(low-to-moderate traffic marketing/portfolio sites; a 30s microcache captures the
same origin protection as long-TTL+purge exactly when traffic warrants it, without a
purge plugin, purge-coverage risk, or cached redirects).

New droplets/sites should be provisioned from this. Live sites already matching:
**MF, AVFTB, CBA** (all 30s microcache, no nginx-helper, no idle Redis).

## The convention (rules)

- **30s FastCGI microcache.** `fastcgi_cache_valid 200 30s;` `404 5m;` — TTL is the
  correctness floor; freshness is bounded at 30s for anonymous visitors.
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
