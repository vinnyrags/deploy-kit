---
status: active
updated: 2026-08-13
---

# nginx / PHP-FPM 5xx Triage Runbook

> **What this is:** a working reference for when one of *my own* sites (Shucked, CBA, itzenzo, etc.) throws a 5xx and I need to fix it — the kind of thing I'd normally work through with AI in the loop, distilled so I'm not starting cold. It is **not** interview homework, and server ops is **not** a craft I'm trying to become fluent at performing live. It's the substrate my WordPress work runs on; this doc is here so the substrate doesn't stop me. Lean on it (and on AI) as needed — that's the intended workflow, not a fallback to feel bad about.
>
> Origin: written after the Dealer Alchemist final round, which correctly tested live sysadmin as its *core* competency and surfaced that ops-core roles are a mis-target for me ([post-mortem](../interviews/dealer-alchemist-prep.md)). Keeping the knowledge; dropping the "must drill this cold" framing.

---

## The one rule

**Read the error, don't guess the error.** Every 5xx on this stack writes a line saying exactly what failed. Your first move is never a hypothesis — it's `tail` the nginx error log. Talking through a guess before you've read the log is the exact thing that reads as "doesn't actually operate prod."

```bash
tail -n 50 /var/log/nginx/error.log
```

That line tells you which branch of this runbook you're on. Everything below is "what the log line means."

---

## Decode the status first

| Code | Meaning | Where the fault is |
|---|---|---|
| **502 Bad Gateway** | nginx reached the upstream but got a broken/no response | **Upstream is down or unreachable** — FPM stopped, socket path wrong, upstream crashed |
| **504 Gateway Timeout** | nginx reached the upstream, upstream never answered in time | **Upstream is alive but too slow** — long query, stuck PHP, exhausted workers, deadlock |
| **500 Internal Server Error** | upstream *ran* and returned an error | **App-level** — PHP fatal, uncaught exception, bad `.htaccess`→nginx rewrite, permissions |
| **503 Service Unavailable** | nginx (or upstream) is deliberately refusing | maintenance mode, `limit_req`/`limit_conn` throttle, FPM "server reached max_children" |
| **`000` / "empty reply" (curl 52)** | connection opened, then closed with no HTTP response | **Not a 5xx.** Often you're hitting the WRONG host — see the gotcha below — or a worker segfault |

**502 vs 504 is the whole fork:** 502 = "nobody's home," 504 = "someone's home but not answering." They lead to different commands. Say which one you're on, out loud, before moving.

### ⚠️ Gotcha: `000`/empty-reply looks like an outage but usually isn't — check the host first
If **every** request returns `000` (curl "empty reply", error 52) yet `systemctl is-active nginx` is `active`, `nginx -t` passes, memory/disk are fine, and there are **no worker-crash lines** in the error log — **you're probably testing the wrong hostname, not looking at a down site.**

A hardened server often has a **default_server that drops unmatched hosts**:
```nginx
server { listen 80 default_server; server_name _; return 444; }   # 444 = close connection, no response
```
So a request whose `Host` doesn't match a real vhost (e.g. hitting the **bare IP** after the site moved to a proper hostname) gets silently closed → looks exactly like a total outage. Meanwhile real users on the correct hostname are served `200`.

**Before touching anything, prove the site is actually down:**
```bash
tail -n 5 /var/log/nginx/access.log         # are real 200s still flowing? then it's UP
ls /etc/nginx/sites-enabled/                 # spot a *-drop-default / catch-all
grep -r "server_name" /etc/nginx/sites-enabled/   # what host does the real vhost expect?
curl -s --resolve HOST:443:IP https://HOST/ -o /dev/null -w '%{http_code}\n'   # test the RIGHT host
```
Lesson learned the hard way (2026-07): chased a phantom outage with needless php-fpm/nginx restarts because I kept curling the **bare IP** after the vhost had been moved to `staging.<site>.com` + a `return 444` default. The access log showed live `200`s the whole time. **Read the access log before you restart anything.**

---

## 502 Bad Gateway — the drill

nginx couldn't get a valid response from PHP-FPM. Walk it upstream-ward.

**1. Read the nginx error log — it names the failure verbatim.**
```bash
tail -n 30 /var/log/nginx/error.log
```
- `connect() to unix:/run/php/php8.4-fpm.sock failed (2: No such file or directory)` → **socket doesn't exist** → FPM is stopped, or the path in the server block is wrong. Go to step 2/4.
- `connect() ... failed (13: Permission denied)` → socket exists but nginx can't use it → **ownership/mode mismatch** (`listen.owner`/`listen.group` in the pool ≠ nginx user). Go to step 5.
- `upstream prematurely closed connection` / `recv() failed` → FPM **accepted then died** mid-request → a worker crashed (segfault, OOM-killed). Go to step 3 + check `dmesg`.
- `no live upstreams` → nginx marked the whole upstream dead → FPM down or all workers busy.

**2. Is PHP-FPM even running?**
```bash
systemctl status php8.4-fpm       # active? or failed/dead?
```
If dead: `journalctl -u php8.4-fpm -n 50 --no-pager` tells you *why* it won't start (usually a syntax error in a pool/`.ini` after an edit). Fix the cause, then `systemctl restart php8.4-fpm`. **Don't just restart blindly** — if it died from a bad config it'll die again, and restarting-without-reading is the tell.

**3. Did a worker crash rather than the master?**
```bash
journalctl -u php8.4-fpm -n 50 --no-pager      # "child exited on signal 11 (SIGSEGV)"?
dmesg | tail -n 20                             # "Out of memory: Killed process ... php-fpm"?
```
OOM-killed workers → memory pressure (undersized droplet, `pm.max_children` too high for RAM, a runaway request). Segfault → often a broken PHP extension (opcache, a native ext) after an update.

**4. Does the socket the pool defines match the socket nginx dials?** This is the single most common self-inflicted 502.
```bash
grep -R "listen" /etc/php/8.4/fpm/pool.d/          # e.g. listen = /run/php/php8.4-fpm.sock
grep -R "fastcgi_pass" /etc/nginx/                 # must be the SAME path (or 127.0.0.1:9000)
ls -l /run/php/                                    # does that socket file actually exist?
```
Mismatch (someone upgraded PHP 8.3→8.4 and the server block still points at `php8.3-fpm.sock`) → fix the `fastcgi_pass`, `nginx -t`, reload.

**5. Permissions on the socket.**
```bash
ls -l /run/php/php8.4-fpm.sock                     # owner/group should be usable by nginx (www-data)
grep -E "listen.owner|listen.group|listen.mode" /etc/php/8.4/fpm/pool.d/www.conf
```

**6. Confirm the upstream directly, cutting nginx out of the picture** (proves which side is broken):
```bash
# TCP pool:
cgi-fcgi -bind -connect 127.0.0.1:9000            # or:
curl --unix-socket /run/php/php8.4-fpm.sock http://localhost/ping   # if a /ping status path is enabled
```
Upstream answers but nginx still 502s → it's nginx-side (path/perms). Upstream also fails → it's FPM-side (down/crashed).

**7. Fix, then reload safely — never `restart` nginx blind:**
```bash
nginx -t && systemctl reload nginx                # -t validates config BEFORE you apply it
```

---

## 504 Gateway Timeout — the drill

Upstream is alive but didn't answer inside the timeout. It's a *slowness* problem, not a *down* problem.

**1. Confirm it's slow, not dead:** `systemctl status php8.4-fpm` = active, error log says `upstream timed out (110: Connection timed out)`.

**2. Are all FPM workers busy?** (the usual real cause under load)
```bash
journalctl -u php8.4-fpm | grep -i "max_children"   # "server reached pm.max_children"
```
If yes → requests are queuing. Either work is genuinely slow (fix the slow thing) or the pool is undersized (`pm.max_children`).

**3. What are the workers *doing*?** Find the slow request.
```bash
mysqladmin -u root -p processlist                   # a query stuck in "Sending data" for 30s?
tail -f /var/log/mysql/mysql-slow.log               # if slow query log is on
```
On WordPress this is almost always a slow query (missing index, `SELECT ... ORDER BY rand()`, an autoloaded-options bloat, a plugin doing an unbounded meta query). `EXPLAIN` the offender → `type: ALL` + big `rows` = full scan → add the index.

**4. Only *after* finding the cause,** consider raising `fastcgi_read_timeout` / `pm.max_children` — but raising the timeout to hide a slow query is treating the symptom. Say that out loud; it signals ops judgment.

---

## 500 Internal Server Error — the drill

The app ran and errored. Go to the **PHP** logs, not the nginx ones.

**1. PHP-FPM / app error log:**
```bash
tail -n 50 /var/log/php8.4-fpm.log
tail -n 50 /var/www/<site>/wp-content/debug.log     # if WP_DEBUG_LOG is on
```
Look for `PHP Fatal error:` — it names the file and line. Common: fatal after a plugin/PHP update (deprecated call removed in 8.x), uncaught exception, `Allowed memory size exhausted`.

**2. WordPress-specific fast checks:**
- Just updated PHP? A plugin calling a function removed in 8.x fatals. `wp plugin deactivate <slug>` to bisect.
- White screen + nothing in the log → bump `memory_limit`, set `WP_DEBUG_LOG` on, reload.
- 500 *only* on non-homepage URLs → it's not PHP, it's **rewrites** (see below), which surfaces as 404/500 depending on config.

**3. Permissions / ownership** after a migration or a botched deploy:
```bash
ls -l /var/www/<site>/                               # files should be owned by the FPM/web user
# "failed to open stream: Permission denied" in the PHP log = this
```

---

## Bonus: front-page-works-everything-else-404 (the Shucked bug)

Not a 5xx, but the same "read before guessing" reflex. After removing a plugin or migrating, WordPress permalinks break because rewrite rules are stale:
```bash
wp rewrite flush --hard
wp cache flush
```
Homepage resolves (it's the root route) but `/about` 404s → stale rewrites, every time.

---

## The 60-second first-pass, memorized

For **any** 5xx, in order, out loud:

1. `tail -n 50 /var/log/nginx/error.log` — **read the actual error line.**
2. Name the code's meaning: 502 = upstream down/unreachable · 504 = upstream slow · 500 = app errored.
3. `systemctl status php8.4-fpm` — is the upstream even alive?
4. If 502: does the **socket path** in the pool match `fastcgi_pass`, and does the file exist? (`grep listen`, `grep fastcgi_pass`, `ls -l /run/php/`)
5. If 504: `mysqladmin processlist` / slow log — find the slow thing.
6. If 500: `tail` the **PHP** log, read the `Fatal error:` line.
7. Fix the cause → `nginx -t && systemctl reload nginx` (validate, never blind-restart).

**Talk while you do it.** In a live exercise they're buying the *reasoning*, not the fix. "It's a 502, so nginx reached the upstream but got nothing — let me read the error log before I guess" is worth more than silently typing the right command.

---

## Symptom → likely cause, at a glance

When one of my sites throws a 5xx, match the symptom here, then jump to the matching drill above (or hand the symptom + the relevant log line to AI and let it drive):

| Symptom | Likely cause |
|---|---|
| 502, log: socket "No such file" | FPM stopped, or `fastcgi_pass` points at a stale PHP version's socket |
| 502, connect() failed | wrong socket path in the server block (common after a PHP upgrade) |
| 502, "Permission denied" | socket ownership/mode mismatch vs. the nginx user |
| 504 / "max_children" in log | workers exhausted — slow work backing up, or undersized pool |
| 504, request stuck in `processlist` | slow MySQL query (missing index / unbounded meta query) |
| 500, Fatal in PHP log | PHP fatal — often a plugin calling something removed in PHP 8.x |
| homepage OK, inner pages 404 | stale rewrite rules — `wp rewrite flush --hard` |
| nginx reload fails | typo in the server block — `nginx -t` names the line |

No shame in reaching for AI on any of these — that's the normal workflow, and this table just gets the first useful signal into the prompt faster.
