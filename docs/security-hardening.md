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
| `location ~ wp-config-env\.php` | DB password + all eight salts never served |
| `location ^~ /scripts/` | Operational scripts never served from the docroot |

> **`wp-config-env.php` was added 2026-08-28 and is not yet rolled out.** The rule is in this repo;
> the running droplets still need the snippet copied to them. Until then all four ARTHOUSE droplets
> serve `/wp-config-env.php` at **200** (six vhosts — Shucked is excepted, it keeps its secrets
> inline in `wp-config.php` and has no such file). Nothing leaks today: the file is only `define()`
> calls, so PHP executes it and returns an empty body. It becomes credential disclosure the moment
> PHP-FPM is down or the handler breaks. Roll out per droplet with
> `cp nginx/wp-hardening.snippet.conf /etc/nginx/snippets/wp-hardening.conf && nginx -t && systemctl
> reload nginx`, then confirm `curl -o /dev/null -w '%{http_code}\n' https://<site>/wp-config-env.php`
> returns **403**. Re-running `harden.sh` does the same thing — step 3 always re-copies the snippet,
> and the vhost loop no-ops because the include is already present on all eight vhosts.

## Usage

```bash
harden.sh --check              # report current state, change nothing
harden.sh --only <vhost>       # apply, patching only that vhost — staging first
harden.sh                      # apply to every enabled vhost
```

---

## Outbound mail — `provision/mail.sh`

Every droplet ships with `sendmail_path` pointing at `/usr/sbin/sendmail` and **no MTA behind it**,
so `wp_mail()` fails silently: password resets, form notifications and admin notices all vanish with
no error anyone sees. `mail.sh` installs the msmtp relay that fixes it.

```bash
mail.sh --check                                              # report, change nothing
mail.sh --provider resend --key-file /root/.resend_key \
        --from noreply@example.com --test-to you@example.com
mail.sh --test-to you@example.com                            # verify only
```

The API key is read from a **file or stdin, never an argument** — arguments are visible to any user
via `ps`.

### The permission bug this exists to prevent

msmtp's config holds a password, so the instinct is `0600 root:root`. **That is wrong, and it fails
in the most misleading way available.** PHP-FPM runs as `www-data`; a root-only config means every
*web-initiated* email fails with `account default not found: no configuration file available`, while
every `wp-cli` send over SSH succeeds because root can read the file.

So the box looks healthy from a terminal and is broken for real users. `vincentragosta.io` sat like
that from 2026-05-11 to 2026-08-28 — `msmtp.log` full of `exitcode=EX_OK` entries, all of them
root's, while WordPress issued password-reset keys with no send at all. Three separate
investigations misdiagnosed it: "no MTA binary" said broken when it worked; `wp_mail()` returning
`true` said working when only root worked; reading the log said working because the entries were
root's.

The file must be **`0640 root:www-data`**. msmtp only rejects a config that is group/world
*writable*; group-readable is fine. `mail.sh` sets this, and `--check` flags it if something else
has changed it.

> **Never verify mail with `wp eval` over SSH.** That is the one context that works while the site
> is broken. Use `--test-to`, which sends as `www-data`, and then read the *delivered* headers — a
> `250` from the relay only proves it was accepted for relay, not that it authenticated or arrived.

### Deliverability

The From address must be on a domain the provider has **verified**, or the message is refused
(Resend) or silently rewritten to the authenticated account (Gmail — mail then arrives from a
personal mailbox, which reads as phishing on a password reset).

**Verify the domain, not a single sender address.** Domain verification is what yields a DKIM
signature aligned to the site's own domain, and DKIM alignment is what DMARC actually checks. A
working result looks like this in the delivered headers:

```
dkim=pass  header.i=@<site-domain>
spf=pass
dmarc=pass header.from=<site-domain>
```

The application half is `IX\Providers\Theme\Hooks\MailIdentity`, which sets the WordPress From
address. It is inert until `IX_MAIL_FROM` is defined in that environment's `wp-config-env.php` — so
the relay and the From address are configured in the same place, per environment.

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

## Not built: the audit script, and monitoring

Everything in this document was verified by hand during the 2026-08-24/25 sweep — ad-hoc curl and
ssh, reconstructed from scratch each time. There is no script that runs the checklist.

The obvious next tool is `provision/audit.sh`: the four username-enumeration vectors, xmlrpc on both
`/xmlrpc.php` and `/wp/xmlrpc.php`, PHP execution under uploads, `/scripts/` exposure, admin-account
count, database dumps sitting in a docroot, ufw state, swap, and cert expiry. Read-only, one host or
the fleet, exit non-zero on a finding.

Monitoring is that same script on a timer, alerting only on change. **Both are deliberately parked**
— Marc declined monitoring for ARTHOUSE on 2026-08-26 and the personal sites are held with it. This
is a decision, not a backlog item that got forgotten; do not re-pitch it unprompted.

Worth recording why it was proposed: the Celebrity Autobiography spam went unnoticed for roughly a
fortnight, and most of what the sweep found was months old. That is why it all landed at once as an
emergency rather than as routine maintenance. If there is ever another compromise or near-miss, that
is the argument to bring back.

The audit script has value even without the alerting half, since it turns a two-day investigation
into a five-minute command.

## Related

- [cloudflare-edge-settings.md](cloudflare-edge-settings.md) — real-IP detail, and the still-open
  origin-bypass gap
- [deploy-doctrine.md](deploy-doctrine.md) — why server-side changes get reverted
