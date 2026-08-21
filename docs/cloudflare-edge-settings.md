---
status: active
updated: 2026-08-20
---

# Cloudflare edge settings — fleet notes

Zone-level Cloudflare settings that have bitten us, and how to inspect or change them.
Applies to every **proxied** zone. Sites that are DNS-only at Cloudflare (Shucked) or not
on Cloudflare at all (CBA, vincentragosta.io, itzenzo.tv) are unaffected by everything here.

## Encrypted ClientHello (ECH) — disabled fleet-wide 2026-08-20

**ECH is off on `viewfromthebridgeplay.com` and `matchbookfestival.com`.** Keep it off.

### What happened

ARTHOUSE staff could not reach `viewfromthebridgeplay.com`, getting Chrome's
`ERR_SSL_PROTOCOL_ERROR` ("sent an invalid response") on home wifi while the same
devices loaded the site fine on cellular. The site was completely healthy throughout —
200s over IPv4 and IPv6, valid certs at both edge and origin, no origin errors, not
compromised.

ECH encrypts the SNI inside the TLS ClientHello. Middleboxes that expect to read the
hostname in cleartext — consumer ISP filtering, some security suites, some residential
router firmware — drop or mangle the handshake, and the browser reports it as a protocol
error. **The failure happens before the request ever reaches the origin, so nothing
appears in nginx logs.** That is the signature.

### Diagnosing it

`ERR_SSL_PROTOCOL_ERROR` + works-on-cellular + healthy origin ⇒ suspect ECH.

Confirm without changing anything server-side: have the affected user turn **off**
Chrome → Settings → Privacy and security → Security → **Use secure DNS**, then reload.
Chrome only uses ECH when it can fetch the HTTPS record over secure DNS, so if the site
loads with that off, ECH is the cause. Have them turn it back **on** afterwards — it is a
diagnostic, not a fix, and leaving it off costs them DNS privacy.

### Checking whether ECH is on

The authority is the zone's HTTPS/SVCB record — not the dashboard, and not the API's
success message. Look for SvcParam key **5** (`ech`), or the string `cloudflare-ech.com`:

```bash
dig @1.1.1.1 <domain> TYPE65 +short
```

macOS's bundled `dig` (9.10.x) predates the `HTTPS` record type and silently rewrites the
query to `A` — **always use the numeric `TYPE65`**, and check the QUESTION section if a
result looks suspicious. An ECH-bearing record runs ~136 bytes; without it, ~61.

### Turning it off — API only

**The dashboard toggle does not exist on Free zones.** Cloudflare's docs say "ECH is
enabled by default on Free zones. Other plans can turn it on or off," and the SSL/TLS →
Edge Certificates page simply omits the control. That is a dashboard-only restriction:
**the API reports `"editable": true` on Free and honours the change.** Do not upgrade a
zone to Pro just to get this toggle.

```bash
# needs a token with Zone:Zone Settings:Edit (+ Zone:Zone:Read to resolve ids)
curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ech" \
  -H "Authorization: Bearer $CF_TOKEN"

curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ech" \
  -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
  --data '{"value":"off"}'
```

Then **verify against the HTTPS record**, not the API response. Staging inherits the zone
setting, so a subdomain on the same zone is covered automatically.

Use a short-TTL token scoped to the specific zones, and delete it afterwards.

### Watch item

Cloudflare has enabled ECH on zones unprompted. A site that was fine for weeks can start
failing for a subset of visitors with no deploy on our side. **If this symptom reappears,
re-check `TYPE65` before investigating anything else** — and check the zone audit log to
see whether Cloudflare flipped it back.

Zone ids: AVFTB `cb38a7eae662d5981a5fa7b814917eb8` · MBF `3bb7322443a62e2b5ead8f4a06f4d3f1`.

## Origin visibility gap — `set_real_ip_from` is not configured

Neither the AVFTB nor the MBF droplet restores the visitor IP from Cloudflare, so
`/var/log/nginx/access.log` records **Cloudflare edge IPs** (`104.23.x`, `172.70.x`,
`162.158.x`) for every request. You cannot trace a specific reporter's requests, which
actively slows down incident triage.

Fix is the standard `set_real_ip_from` block for Cloudflare's published ranges plus
`real_ip_header CF-Connecting-IP;`. Not yet done on any box — do it before the next
incident rather than during one.
