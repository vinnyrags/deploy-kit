# Security hardening

`provision/harden.sh` applies WordPress hardening to an **already-provisioned** droplet.

`provision-base.sh` only runs on fresh boxes. Every droplet in the fleet is already provisioned and
its vhosts have been edited in place by certbot, so hardening has to be applied additively to a
running box. Regenerating vhosts from `vhost.conf.template` would destroy the TLS config — don't.

## Why this exists

Celebrity Autobiography was compromised on 2026-08-11. An attacker logged in as the shared
`arthouse` administrator using **valid credentials**. They did not guess the username:
`/author/arthouse/` was indexed and `/?author=1` handed it over on request. No backdoor was found.

Read that twice before tuning anything here, because it sets the honest ceiling on what this
script buys you: **none of it stops an attacker who already holds working credentials.** 2FA on the
shared account is the control that would have stopped that intrusion. Everything below is depth.

## What it installs

| Path | Purpose |
|---|---|
| `conf.d/00-cloudflare-realip.conf` | Restores real visitor IPs behind Cloudflare |
| `conf.d/wp-security.conf` | Defines the `wp_login` rate-limit zone (definition only) |
| `snippets/wp-hardening.conf` | The per-vhost rules, included inside each `server` block |

The snippet carries:

| Rule | Effect |
|---|---|
| `limit_req zone=wp_login burst=10` | 30r/m/IP on `wp-login.php` only |
| `location ~ ^/(wp/)?xmlrpc\.php$` | 403 on both layouts |
| `location ~* /(?:uploads\|files)/.*\.php$` | PHP in uploads cannot execute |
| `location ^~ /scripts/` | Operational scripts never served from the docroot |

## Usage

```bash
harden.sh --check              # report current state, change nothing
harden.sh --only <vhost>       # apply, patching only that vhost — staging first
harden.sh                      # apply to every enabled vhost
```

Idempotent. Re-running is safe and is also how you refresh the Cloudflare ranges.

Backups go to `/root/nginx-bak/harden-<stamp>/` with a `manifest.txt` recording where each vhost
actually came from. If `nginx -t` fails, the script restores everything and exits non-zero.

## Four things that are load-bearing

Each of these was learned by getting it wrong on a live box.

**1. Real-IP must land before rate limiting.** On a proxied site, `limit_req` without real-IP keys
on the Cloudflare edge IP, bucketing every visitor into ~20 shared keys. That throttles real users
and barely touches an attacker. Both land in the same run — don't split them.

**2. `limit_req` belongs in the snippet, not `conf.d`.** The zone is defined in http context
because `limit_req_zone` has to be, but *applying* it there means box-wide: `--only <staging
vhost>` silently rate-limited production on the same droplet. `limit_req` is valid in server
context, so it lives in the per-vhost snippet and `--only` means what it says.

**3. Patch `sites-enabled`, not `sites-available`.** On three of the four ARTHOUSE droplets
`sites-enabled` holds **real files**, not symlinks, and they have drifted from their
`sites-available` namesakes. Patching `sites-available` there edits a file nginx never reads,
reports success, and changes nothing — a silent no-op. The script resolves with `readlink -f`,
which handles both layouts.

**4. Match both xmlrpc paths.** `vhost.conf.template` historically blocked only
`location = /xmlrpc.php`. That is correct for a classic layout and **wrong** for the Bedrock-style
layout where core lives in `/wp`. Every Mythus site was serving `/wp/xmlrpc.php` at 200 while the
rule looked present and correct. The regex form covers both.

## Tuning notes

Rate is **30r/m burst 10**, deliberately looser than the 20r/m burst 5 first tried. These agencies
sit behind one office NAT, so colleagues logging in within a minute share a bucket; at 20/5,
throttling started around the 9th request in ten seconds — close enough to real usage to risk
locking someone out.

Loosening costs little defensively. The CBA intruder came from ~25 rotating IPs, so per-IP limiting
was never going to stop that. What it stops is single-IP hammering — Shucked absorbed 21,793 login
attempts, which is exactly that shape. At 30r/m one IP manages ~1,800/hour instead of tens of
thousands.

Throttles appear as 429s on `wp-login.php` in the **access** log. They do not reliably reach
`error.log` even with `limit_req_log_level warn`, so grep the access log when investigating.

## Verifying

Run these from your laptop, not the box — a local curl skips Cloudflare and any edge rules.

```bash
curl -o /dev/null -w '%{http_code}\n' -X POST https://<site>/xmlrpc.php      # want 403
curl -o /dev/null -w '%{http_code}\n' -X POST https://<site>/wp/xmlrpc.php   # want 403
for i in $(seq 1 25); do curl -o /dev/null -s -w '%{http_code} ' https://<site>/wp/wp-login.php; done
# want ~11 x 200 then 429s
curl -o /dev/null -w '%{http_code}\n' https://<site>/?cb=1                   # want 200 — must NOT be throttled
```

That last check is the one people skip. It proves the limit keys on `wp-login.php` alone rather
than the whole vhost. Cache-bust it, or a FastCGI hit will tell you nothing.

When hardening staging on a shared droplet, run the same burst against **production** afterwards
and confirm zero 429s. That is the only real proof `--only` was honoured.

## Two things that look like regressions and are not

Both of these were investigated as incidents during the 2026-08-25 sweep and both were false.

**A staging sitemap returning 404 is usually correct.** `blog_public=0` makes core disable sitemaps
entirely (`wp_sitemaps_get_server()->sitemaps_enabled()` returns false), so `/wp-sitemap.xml` falls
through to the theme's 404 template and returns `content-type: text/html`. That is the intended
state for a `noindex` staging site.

Do not confuse it with the genuine bug fixed on Shucked, which looks different: **valid sitemap XML
served with a 404 status**, caused by `WP::handle_404()` firing on a site with zero published posts
and a static front page. Check `blog_public` first — if it is `0`, there is nothing to fix.

**Cloudflare injects a managed robots.txt on proxied zones.** It adds a block disallowing AI
crawlers — GPTBot, ClaudeBot, CCBot, Amazonbot, Bytespider, Google-Extended, meta-externalagent and
others — while giving `User-agent: *` an explicit `Allow: /`.

A grep for `Disallow: /` that ignores which user-agent block it sits in reads this as "the site has
been deindexed". It has not been; Googlebot and Bingbot are unaffected. Parse by block:

```bash
curl -s https://<site>/robots.txt | awk '
  /^User-agent:/ { ua = tolower($2) }
  /^Disallow: \/$/ { if (ua == "*" || ua == "googlebot") print "BLOCKED for " ua }'
```

The block appears only on proxied zones, so it is also a quick way to tell whether a site is behind
Cloudflare at all.

## The WordPress half

nginx cannot close username enumeration — that is application-level. IX **v1.7.0**'s
`DisableAuthorArchives` Feature closes all four routes core uses to publish valid login names:
`/author/<login>/`, `/?author=<id>` (which 301s and leaks the name in `Location`),
`wp-sitemap-users-1.xml`, and `/wp-json/wp/v2/users`.

On by default and capability-gated — anyone who can already `list_users` keeps normal behaviour, so
the block editor's author dropdown still works. Verified with a real admin session on staging, not
assumed.

Two things to know when testing it:

- A REST nonce is bound to the session token in the logged-in cookie. Generating one in a CLI
  process with no cookie produces a nonce that fails with `rest_cookie_invalid_nonce` — that is a
  broken test, not a broken feature.
- On patched sites `/wp-sitemap-users-1.xml` returns **200 with an HTML body** rather than a hard
  404. No usernames leak, but it is a soft-404 worth tidying in a later IX patch.

Sites not on the Mythus stack cannot take this fix and need the equivalent mu-plugin
(`mu-plugins/000-harden-user-enumeration.php`).

**The version is pinned in each site's committed `composer.lock`.** Never upgrade IX on a droplet —
the post-receive hook reinstalls from that lock and will silently revert you. See
[deploy-doctrine.md](deploy-doctrine.md).

## Related

- [cloudflare-edge-settings.md](cloudflare-edge-settings.md) — real-IP detail, and the still-open
  origin-bypass gap
- [deploy-doctrine.md](deploy-doctrine.md) — why server-side changes get reverted
