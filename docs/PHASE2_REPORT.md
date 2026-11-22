# Phase 2 Report: Harden, Recover, Troubleshoot

**Team:** dimaginaxal (Section C)
**Members:** Sachin Jaiswal (2401010399), Md. Sajjan (2401010272), Sibtain Ahmed Qureshi (2401010454), Viraj Chafale (2401020076)
**Test date:** 22–23 November 2026
**Evidence:** `evidence/phase2/`. File names start with the extension letter.

---

## 1. What changed from Phase 1

### Network

The Wi-Fi DHCP assigned new addresses. All Phase 2 configs use these:

| Mac | Member | Phase 1 IP | Phase 2 IP | Phase 2 roles |
| --- | --- | --- | --- | --- |
| Mac 1 | Md. Sajjan | 10.7.2.83 | 10.7.12.240 | Primary DNS (dnsmasq), test client |
| Mac 2 | Sachin Jaiswal | 10.7.1.138 | 10.7.29.80 | Edge nginx: TLS, load balancing, failover |
| Mac 3 | Sibtain Ahmed Qureshi | 10.7.12.144 | 10.7.27.218 | Backend A, **backup DNS**, **standby edge** |
| Mac 4 | Viraj Chafale | 10.7.16.85 | 10.7.11.150 | Backend B, main test client |

### Configuration and code

| File | Change | Why |
| --- | --- | --- |
| `config/phase2/dnsmasq-primary.conf` | `local-ttl=30` (Phase 1 used the default 0), test record `ttl.dimaginaxal.test`, `log-queries` | Extension B: clients now cache answers, so TTL behaviour is visible |
| `config/phase2/dnsmasq-backup.conf` | New: same records on Mac 3 | Extension A |
| `config/phase2/nginx.conf` | `max_fails=1 fail_timeout=10s`, `proxy_next_upstream error timeout http_502 http_503 http_504`, `proxy_connect_timeout 2s`, access log with `$upstream_addr`, `X-Edge` header, `http2 on` | Extension D failover, Extension E visibility, HTTP/2 |
| `config/phase2/nginx-standby.conf` | New: identical except `X-Edge: mac3-standby` | Extension E |
| `config/phase2/pf-backend-a.conf`, `pf-backend-b.conf` | New: allow only 10.7.29.80 to ports 3001/3002 | Extension C |
| `backend-a/server.js`, `backend-b/server.js` | `ETag` header, `If-None-Match` → **304**, new `/api/info` endpoint with the same body on A and B | Closes the Phase 1 caching gap |
| `scripts/diagnose.sh` | New: layer-by-layer check (DNS → IP → TCP → TLS → HTTP → backends) | Extension F |

### Phase 1 gaps closed

- **304 Not Modified** now works through the edge: `curl -sI -H 'If-None-Match: "55d7f080e5780b68"' https://app.dimaginaxal.test/api/info` returns `HTTP/2 304` (`01-304-not-modified.png`). `/api/info` has an identical body on both backends, so the ETag matches whichever backend answers.
- **CA trust** was added on Mac 4 (Viraj), so HTTPS now verifies on that client without `-k`.
- **HTTP/2** is enabled on the edge. Responses show `HTTP/2 200`.

---

## 2. Tests and results

### Extension A: Backup DNS resolver

**Setup:** dnsmasq on Mac 1 (primary) and Mac 3 (backup) with identical records. Clients set with `networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218`.

| Step | Evidence | Result |
| --- | --- | --- |
| Before | `dig @10.7.12.240` and `dig @10.7.27.218`: both return `10.7.29.80` | Both servers hold the same record |
| Primary stopped (Ctrl+C on Mac 1) | `A1-…png` (00:16:00), `A2-…png` (00:16:40) | `app.dimaginaxal.test 30 IN A 10.7.29.80`, **`SERVER: 10.7.27.218#53`**, query time 19 ms / 92 ms. The client was answered by the backup |
| Primary restarted | `A3-primary-dns-restored.png` (00:18:42) | `SERVER: 10.7.12.240#53` again |

**DNS failure vs application failure:** when the DNS service fails, the name cannot be resolved at all (`curl: (6) Could not resolve host`). We saw exactly this on Mac 4 before it was pointed at our resolvers (section 3). When the application fails, `dig` still returns `10.7.29.80` and the TLS connection to nginx works, but the response is `502 Bad Gateway` (`D7-…png`).

### Extension B: DNS TTL and controlled record change

**Setup:** `local-ttl=30` on both servers. `ttl.dimaginaxal.test` initially pointed to `10.7.29.80`. A client watcher queried the macOS resolver cache (`dscacheutil -q host`) every 3 s.

| Step | Evidence | Result |
| --- | --- | --- |
| TTL visible | `dig` output in `A1–A3` | `30 IN A`, where Phase 1 showed TTL 0 |
| Record changed to `10.7.11.150` on **both** servers | `B1-ttl-record-change-after-30s.png` | Watcher showed `10.7.29.80` until **00:25:24**, then `10.7.11.150` from **00:25:27**. The cached answer was served until it expired |
| Record reverted to `10.7.29.80` | `B2-ttl-record-revert.png` | Watcher kept the cached `10.7.11.150` until **00:30:52**, then `10.7.29.80` from **00:30:55** |

`dig` queries the DNS server directly and bypasses the OS cache, so it showed the new value immediately. Applications (curl, browser) use the OS cache and kept the old value for up to one TTL. Running `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` clears the cache, and the next lookup returns the new value at once.

### Extension C: Service isolation with pf

**Setup:** rollback copies saved first (`pfctl -s info`, `pfctl -sr`, `/etc/pf.conf`), then `sudo pfctl -f config/phase2/pf-backend-a.conf && sudo pfctl -e` on Mac 3, and the same with `pf-backend-b.conf` on Mac 4. Rules: pass loopback, pass TCP from `10.7.29.80` to the backend port, `block drop` everything else to that port.

| Test | Evidence | Result |
| --- | --- | --- |
| Mac 1 → `10.7.27.218:3001` | `C1-…png` | `curl: (28) Failed to connect … after 5006 ms: Timeout was reached` |
| Mac 1 → ping Mac 3 | `C2-…png` | 3/3 received, 0% loss. The host is reachable; only the port is blocked |
| Mac 1 → ping Mac 4 | `C3-…png` | 3/3 received (high Wi-Fi latency, up to 1874 ms) |
| Mac 2 (edge) → both backends | `C4-…png` | `{"backend":"A"…}{"backend":"B"…}`. The edge is still allowed |
| After rollback (`pfctl -f /etc/pf.conf`), Mac 1 → 3001 | `C5-…png` | `{"backend":"A","status":"ok"}`. The original rules are restored |

The client sees a **timeout** rather than "connection refused" because `block drop` discards the SYN silently. `block return` would send a RST and curl would report "refused".

### Extension D: High-availability failover

**Setup:** Phase 2 nginx config on Mac 2. A client loop requested `/api/status` every second, while `tail -f edge.log` showed `upstream=` and `upstream_status=` for each request.

| Time | Event | Evidence | Result |
| --- | --- | --- | --- |
| 00:44:18–00:44:45 | Normal | `D1`, `D2` | A and B alternate. Log alternates between `10.7.27.218:3001` and `10.7.11.150:3002` |
| 00:45:34 | Backend A stopped | `D3-edge-log-retry-A-502-then-B.png` | `upstream=10.7.27.218:3001, 10.7.11.150:3002 upstream_status=502, 200`. nginx tried A, failed, retried the **same request** on B, and the client still received **200** |
| 00:45:33–00:45:54 | A down | `D4-backend-A-down-only-B.png` | Every response `{"backend":"B"}`, with no errors shown to the client. A is skipped for `fail_timeout=10s`, then probed again |
| 00:46:44 | Backend A restarted | `D5`, `D6` | Alternation resumes: the log shows `10.7.27.218:3001` again |
| ~00:48:10 | Both backends stopped | `D7`, `D8` | DNS and TLS still succeed, and nginx itself answers `502 Bad Gateway` |

**Remaining single point of failure:** the edge nginx on Mac 2. If Mac 2 fails, DNS still hands out `10.7.29.80` and every client fails, even with both backends healthy. To remove it: (1) two edges sharing a floating virtual IP with VRRP/keepalived, so failover takes about a second; (2) health-checked DNS failover such as Route 53 failover records, which is slower because of the TTL (Extension E is a manual version); (3) a managed cloud load balancer such as AWS ALB spread across availability zones.

### Extension E: Controlled edge migration (DNS-based cutover)

**Setup:** standby nginx on Mac 3 with the same certificate and `X-Edge: mac3-standby`. Verified before the cutover with `curl --resolve app.dimaginaxal.test:443:10.7.27.218 …`, which returned `HTTP/2 200`, `x-backend: A`, `x-edge: mac3-standby`, with no certificate warning. Mac 4 ran a watcher printing the `x-edge` header every 2 s.

| Step | Evidence | Result |
| --- | --- | --- |
| Before | `E1-…png` | `x-edge: mac2-primary` (01:19:08 – 01:19:46) |
| `app`/`api` records changed to `10.7.27.218` on both DNS servers | `E1-…png` | The cached client kept reaching the **old edge** until its cached answer expired, then switched: `x-edge: mac3-standby` from **01:19:48** (about 30 s, one TTL) |
| New client (cache flushed) | (screenshot to add) | Reached `mac3-standby` immediately |

Mac 2's nginx stayed running throughout, so clients holding the old answer were still served while their cache drained and nobody saw an error. Afterwards the records were reverted, the standby nginx was stopped, and the copied private key was deleted from Mac 3.

### Extension F: Faculty-injected troubleshooting challenge

**Method:** always DNS → IP → TCP → TLS → HTTP → backend, stopping at the first failing layer. `scripts/diagnose.sh` automates this and names the failing layer.

| Practice fault | Injected by | Symptom observed | Layer identified | Fix |
| --- | --- | --- | --- | --- |
| _to fill in during practice_ | | | | |

---

## 3. Troubleshooting findings (real problems we hit)

These were not planned faults. Each one was diagnosed with the layer-by-layer method.

| Problem | Symptom | Layer | Cause and fix |
| --- | --- | --- | --- |
| Lab Wi-Fi gave new IPs | Phase 1 configs pointed at dead addresses | IP | DHCP leases changed. Updated every Phase 2 config. Lesson: use reserved or static addresses for infrastructure |
| Client DNS set before the resolvers were running | `dig` timed out, and `git push` failed: `Could not resolve host: github.com` | DNS | Clients depended on resolvers that were not up yet. Reset DNS to the default, re-applied once dnsmasq was running |
| Mac 4 had no DNS servers set | `curl: (6) Could not resolve host`; certificate trust was fine | DNS (client config) | `networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218` |
| VPN DNS (Tailscale, `100.100.100.100`) on Mac 2 | `.test` names returned NXDOMAIN | DNS | The VPN resolver overrides ours. Turn it off for the demo |
| `sudo dnsmasq: command not found` on Mac 3 | Backup DNS would not start | — (setup) | dnsmasq was not installed. `brew install dnsmasq` |
| `bind() to 0.0.0.0:443 failed (48: Address already in use)` | Standby nginx "failed" to start | Transport (port) | `lsof` showed nginx was already listening from the first start. Use `nginx -s reload`, not a second `nginx` |
| URL typo `/api/status;` | `{"error":"Not Found"}` from the backends | Application | DNS, TCP, TLS and the proxy all worked. Only the path was wrong |
| Unstable Wi-Fi | Ping RTT up to 1874 ms to Mac 4 and ~500 ms to Mac 1 | Link | Laptop Wi-Fi power saving. Keep machines plugged in |

---

## 4. Learning summary (one paragraph per extension)

> Draft: each member should rewrite these in their own words before the viva.

**A. Backup DNS.** A resolver list gives redundancy only if every server holds the same data. When the primary stopped, the client simply asked the next server and got an identical answer, so the failure was invisible to users. The new risk is drift: a record changed on one server but not the other gives different answers depending on which server a client asks.

**B. TTL.** TTL is a contract that lets every resolver reuse an answer for that many seconds. `dig` saw the record change instantly because it asks the server directly, while applications kept the cached value for up to 30 s. Short TTLs make changes propagate fast at the cost of more queries. Production teams lower the TTL before a planned migration and raise it afterwards.

**C. Service isolation.** Blocking at the transport layer (a port) is separate from reachability at the network layer: Mac 1 could still ping Mac 3 but could not open port 3001. Restricting backends to the edge means the load balancer is the only way in, which is how private subnets and security groups work in the cloud. A rollback copy is essential, because a firewall mistake can lock you out.

**D. High availability.** nginx detects backend failure passively, when a real request fails, and retries it on the next backend, so the client never sees the error. `fail_timeout` controls how long a failed backend is skipped before it is tried again. This removed the backends as a single point of failure but not the edge itself.

**E. DNS-based cutover.** Moving traffic with DNS is gradual by nature: new lookups go to the new edge at once, while cached clients keep using the old one until their TTL expires. Keeping the old edge running during that window means no client sees an outage. The time a cutover takes is bounded by the TTL.

**F. Troubleshooting.** Checking layers in order (name → address → port → TLS → HTTP → backend) turns "it doesn't work" into a specific, provable fault. Several real problems in section 3 looked similar at first ("curl fails") but sat at different layers, and the error code (6, 7, 28, 60, 502) usually identified the layer immediately.

---

## 5. Evidence still to collect

- [ ] A: a "before" `dig` screenshot showing `SERVER: 10.7.12.240` before the primary was stopped
- [ ] B: the manual flush (`dscacheutil -flushcache`) switching the watcher immediately
- [ ] C: `sudo pfctl -sr` output on Mac 3 and Mac 4; Mac 1 → `10.7.11.150:3002` timing out; a "before" screenshot of Mac 1 reaching both ports
- [ ] E: the new client (cache flushed) showing `mac3-standby` immediately
- [ ] F: at least three practice faults diagnosed with `scripts/diagnose.sh`
- [ ] Phase 1 leftovers: ping between all pairs (Mac 3 → Mac 4), full `curl -v` output, Wireshark capture (DNS → TCP → TLS) of one request
