# Phase 2 Runbook: Harden, Recover, Troubleshoot

Step-by-step instructions for every team member. Work through the parts **in order**: some depend on earlier ones (E needs A and B, and C must be rolled back before E).

| Mac | Person | Phase 1 role | New in Phase 2 |
| --- | --- | --- | --- |
| Mac 1 `10.7.12.240` | Md. Sajjan | Primary DNS | Same records with TTL 30, record changes for B and E |
| Mac 2 `10.7.29.80` | Sachin Jaiswal | Edge nginx | Failover config (D), X-Edge header, main demo client |
| Mac 3 `10.7.27.218` | Sibtain Ahmed Qureshi | Backend A | **Backup DNS (A)**, pf firewall (C), **standby nginx (E)** |
| Mac 4 `10.7.11.150` | Viraj Chafale | Backend B | pf firewall (C), main **test client** |

New files in this repo:

```
backend-a/server.js, backend-b/server.js   ETag + 304 support, new /api/info endpoint
config/phase2/dnsmasq-primary.conf          Mac 1
config/phase2/dnsmasq-backup.conf           Mac 3
config/phase2/nginx.conf                    Mac 2 (failover + X-Edge + HTTP/2)
config/phase2/nginx-standby.conf            Mac 3 (standby edge)
config/phase2/pf-backend-a.conf             Mac 3 firewall
config/phase2/pf-backend-b.conf             Mac 4 firewall
scripts/diagnose.sh                         layer-by-layer troubleshooting
```

The Phase 1 files in `config/` stay untouched: the spec wants both the Phase 1 and the Phase 2 configs.

---

## Part 0: Setup (everyone, about 10 min)

**0.1 Pull the repo** on every Mac:

```bash
git clone https://github.com/sarcaxticlarka/dimaginaxal_section_C.git   # or: git pull
cd dimaginaxal_section_C
```

**0.2 Check your IP did not change.** The university Wi-Fi hands out addresses by DHCP, so the Phase 1 IPs may no longer be the same.

```bash
ipconfig getifaddr en0
```

If **any** IP differs from the table above, stop and update every file that contains it (`grep -rn "10.7." config scripts`), then tell the group. Every config depends on these four addresses.

**0.3 Turn off VPNs and Tailscale** on all four Macs. Tailscale's MagicDNS (`100.100.100.100`) takes over DNS and our `.test` names stop resolving. Check with:

```bash
scutil --dns | grep nameserver
```

**0.4 Ping every pair.** In Phase 1, Mac 3 → Mac 4 was never tested. Everyone runs this and screenshots it:

```bash
for ip in 10.7.12.240 10.7.29.80 10.7.27.218 10.7.11.150; do ping -c 3 $ip | tail -2; done
```

---

## Part 1: Close the Phase 1 gaps

### 1.1 ETag / 304 Not Modified (Mac 3 Sibtain, Mac 4 Viraj)

The backends now send an `ETag`. A request that sends the same `If-None-Match` value gets **304** with no body. Restart each backend with the new code:

```bash
# Mac 3
cd backend-a && node server.js
# Mac 4
cd backend-b && node server.js
```

**Demo (Mac 4, through the edge, no -k):**

```bash
curl -sI https://app.dimaginaxal.test/api/info              # note the ETag value
curl -sI -H 'If-None-Match: "PASTE_ETAG_HERE"' https://app.dimaginaxal.test/api/info
#  -> HTTP/2 304
```

`/api/info` returns the same body on both backends, so the ETag is identical and the 304 works whichever backend answers. (`/api/status` differs between A and B, so its ETags differ too.)

In a browser: open `https://app.dimaginaxal.test/api/info`, open DevTools → Network, and reload. You will see **304**, or "(memory cache)" if within 60 s.

Know the three cases for the viva:

| Case | What happens | Network cost |
| --- | --- | --- |
| Fresh cache hit | Within `max-age=60`, the browser reuses its copy and sends nothing | No request |
| Conditional request | After 60 s the browser asks "still `ETag X`?" and the server answers 304 | Request + headers only |
| Full request | No copy, or the content changed: 200 + full body | Everything |

### 1.2 Trust the CA on Mac 1 and Mac 4 (Sachin → Sajjan, Viraj)

Only Mac 2 and Mac 3 trust our mkcert CA so far. On **Mac 2**:

```bash
open "$(mkcert -CAROOT)"        # AirDrop ONLY rootCA.pem to Mac 1 and Mac 4. NEVER rootCA-key.pem
```

On **Mac 1** and **Mac 4**:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/rootCA.pem
curl -v https://app.dimaginaxal.test/api/status 2>&1 | grep -E "SSL connection|subject|verify ok|HTTP/"
```

### 1.3 Full `curl -v` and a clean handshake capture (Sachin on Mac 2, Viraj on Mac 4)

On Phase 1's B1 we only pasted the response. Keep the **full** output this time:

```bash
curl -v https://app.dimaginaxal.test/api/status 2>&1 | tee evidence/phase2/curl-v.txt
```

Wireshark on **Mac 4**, interface `en0`. Start the capture, then:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder    # forces a fresh DNS query
curl -s https://app.dimaginaxal.test/api/status
```

Stop and save as `evidence/phase2/full-flow.pcapng`. Filter `dns || tcp.port==443` shows the whole story in one capture: DNS query/answer → SYN, SYN-ACK, ACK → ClientHello, ServerHello → Application Data.

---

## Part 2: Extension A, Backup DNS (Mac 1 + Mac 3)

**A.1 Mac 1 (Sajjan):** switch to the Phase 2 config. Stop the old dnsmasq with Ctrl+C, then:

```bash
sudo dnsmasq -C config/phase2/dnsmasq-primary.conf -d
```

**A.2 Mac 3 (Sibtain):** install and run the backup. It runs alongside Backend A in a second terminal.

```bash
brew install dnsmasq
sudo dnsmasq -C config/phase2/dnsmasq-backup.conf -d
```

**A.3 Check both servers answer** (any Mac):

```bash
dig @10.7.12.240   app.dimaginaxal.test +short     # 10.7.29.80
dig @10.7.27.218 app.dimaginaxal.test +short     # 10.7.29.80
```

**A.4 Point the clients at both servers.** On **Mac 4** and **Mac 2** (primary first):

```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218
networksetup -getdnsservers Wi-Fi
scutil --dns | grep nameserver
```

**A.5 The failover demo.** Record it.

1. Mac 4: `dig app.dimaginaxal.test`. The output shows `SERVER: 10.7.12.240`.
2. Mac 1: **Ctrl+C** on dnsmasq (primary down).
3. Mac 4: `dig app.dimaginaxal.test`. dig reports a failure talking to 10.7.12.240, then the answer comes back with **`SERVER: 10.7.27.218`**.
4. Mac 4: `curl https://app.dimaginaxal.test/api/status` still works.
5. Mac 1: start dnsmasq again.

The macOS system resolver may sometimes ask the backup even while the primary is up. That is normal: it is a list of resolvers, not a strict order.

**A.6 DNS failure vs application failure.** Show both and explain the difference:

| Break | `dig` | `curl` | Meaning |
| --- | --- | --- | --- |
| Stop **both** dnsmasq | times out | `Could not resolve host` | DNS failure: we cannot even find the edge |
| Stop **both** backends | answers 10.7.29.80 | `502 Bad Gateway` | App failure: name and edge fine, service behind it down |

Restart everything afterwards.

---

## Part 3: Extension B, TTL and record change (Sajjan on Mac 1, Sibtain on Mac 3, Viraj on Mac 4)

Phase 1 answers had **TTL 0**, so clients never cached. Both Phase 2 configs set `local-ttl=30`. We use a separate test name, `ttl.dimaginaxal.test`, so the real app is not disturbed.

**B.1 Check the TTL** (Mac 4):

```bash
dig ttl.dimaginaxal.test | grep -A1 "ANSWER SECTION"
# ttl.dimaginaxal.test.  30  IN  A  10.7.29.80
```

**B.2 Start a watcher on Mac 4.** This uses the macOS cache, the same lookup the browser and curl use:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
while true; do printf "%s  " "$(date +%T)"; dscacheutil -q host -a name ttl.dimaginaxal.test | awk '/ip_address/{print $2}'; sleep 3; done
```

It prints `10.7.29.80` every 3 s. The first lookup fills the cache.

**B.3 Change the record on both DNS servers.** Mac 1 and Mac 3 edit their config:

```
address=/ttl.dimaginaxal.test/10.7.11.150
```

Then restart each one (Ctrl+C, run the same `sudo dnsmasq ... -d` again). **Both** servers must change. If only one changes, clients get different answers depending on which server they ask. That is a good viva point.

**B.4 Observe** on Mac 4:

- `dig ttl.dimaginaxal.test +short` shows **10.7.11.150 immediately**. dig asks the server directly and skips the OS cache.
- The watcher keeps printing **10.7.29.80** for up to 30 s, then switches to **10.7.11.150**. That is the TTL at work.

**B.5 Manual flush.** Change the record back to `10.7.29.80` on both servers and restart them. Then on Mac 4:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

The watcher switches immediately, with no 30 s wait.

**Viva point:** in production you lower the TTL (say from 3600 to 60) a day **before** a migration, so every cache expires quickly when you switch. You raise it again afterwards.

---

## Part 4: Extension C, Firewall isolation (Mac 3 Sibtain, Mac 4 Viraj)

Goal: only Mac 2 can reach ports 3001 and 3002. Everyone else is blocked, but the site still works through the edge.

**C.1 Before.** From Mac 1, direct access works (screenshot):

```bash
curl --connect-timeout 5 http://10.7.27.218:3001/api/status
curl --connect-timeout 5 http://10.7.11.150:3002/api/status
```

**C.2 Back up the current state.** This is the rollback copy the spec asks for.

```bash
sudo pfctl -s info | head -1 > ~/pf-status-before.txt    # was pf Enabled or Disabled?
sudo pfctl -sr                > ~/pf-rules-before.txt
cp /etc/pf.conf ~/pf.conf.backup
```

**C.3 Load the rules:**

```bash
# Mac 3
sudo pfctl -f config/phase2/pf-backend-a.conf && sudo pfctl -e
# Mac 4
sudo pfctl -f config/phase2/pf-backend-b.conf && sudo pfctl -e
sudo pfctl -sr        # show the active rules on screen
```

**C.4 After:**

| From | Command | Expected |
| --- | --- | --- |
| Mac 2 | `curl http://10.7.27.218:3001/api/status` | works (edge is allowed) |
| Mac 1 | `curl --connect-timeout 5 http://10.7.27.218:3001/api/status` | **times out** |
| Mac 1 | `ping -c 3 10.7.27.218` | still works (only the port is blocked, not the host) |
| Mac 1 / Mac 4 | `curl https://app.dimaginaxal.test/api/status` | still works, A and B alternate |

A timeout rather than "connection refused" is expected: `block drop` throws the SYN away silently. `block return` would send a RST and show "refused" instead.

**C.5 Roll back.** Do this before Part 6.

```bash
sudo pfctl -f /etc/pf.conf
sudo pfctl -d          # only if ~/pf-status-before.txt said Disabled
sudo pfctl -sr         # compare with ~/pf-rules-before.txt
```

---

## Part 5: Extension D, High availability (Sachin on Mac 2, Sibtain on Mac 3)

**D.1 Mac 2 (Sachin):** install the Phase 2 nginx config.

```bash
sudo cp /opt/homebrew/etc/nginx/nginx.conf ~/nginx.conf.phase1.backup
sudo cp config/phase2/nginx.conf /opt/homebrew/etc/nginx/nginx.conf
sudo nginx -t && sudo nginx -s reload
tail -f /opt/homebrew/var/log/nginx/edge.log      # shows upstream= for every request
```

What changed and why:

| Directive | Meaning |
| --- | --- |
| `max_fails=1 fail_timeout=10s` | One failed try and the backend is marked down for 10 s, then tried again |
| `proxy_connect_timeout 2s` | Give up on a dead backend quickly |
| `proxy_next_upstream error timeout http_502 ...` | If a backend fails, **retry the same request on the other one**, so the client never sees the error |
| `add_header X-Edge mac2-primary` | Shows which edge answered (needed in Part 6) |
| `http2 on` | curl now shows `HTTP/2 200`. Use `curl --http1.1` to compare with HTTP/1.1 |

These are **passive** health checks: nginx notices a failure when a real request fails. Active checks (probing `/api/status` every few seconds) need nginx Plus or a module.

**D.2 Watcher on Mac 4:**

```bash
while true; do curl -s https://app.dimaginaxal.test/api/status; echo "  $(date +%T)"; sleep 1; done
```

**D.3 The demo:**

1. A and B alternate.
2. Mac 3: **Ctrl+C** Backend A. The watcher shows **only B** and no errors. The edge log shows A failing and B serving.
3. Mac 3: start Backend A again. Within about 10 s A is back and they alternate again.
4. Optional: stop **both** backends and you get **502 Bad Gateway** (DNS and TLS still OK: the edge is up, nothing behind it).

**D.4 Single point of failure (explain in the viva and the report).** nginx on Mac 2 is still a single point of failure. If Mac 2 dies, DNS still hands out 10.7.29.80 and nobody can connect. Ways to remove it:

- A second edge plus a **floating virtual IP** (keepalived / VRRP): the standby takes over the IP in about a second.
- **DNS failover with health checks** (Route 53 failover records): slower, limited by the TTL. Part 6 shows a manual version.
- In the cloud: a managed load balancer (AWS ALB) that runs across several availability zones.

---

## Part 6: Extension E, DNS-based edge cutover (Mac 3 Sibtain, Mac 2 Sachin, Mac 1 Sajjan, Mac 4 Viraj)

Before starting, check that Part 4 has been rolled back on Mac 3 and Mac 4.

**E.1 Mac 2 (Sachin):** AirDrop the certificate **and** key to Sibtain:
`/opt/homebrew/etc/nginx/certs/app.dimaginaxal.test.pem` and `app.dimaginaxal.test-key.pem`.
The key is private. Delete it from Mac 3 after the demo.

**E.2 Mac 3 (Sibtain):** set up the standby edge.

```bash
brew install nginx
sudo mkdir -p /opt/homebrew/etc/nginx/certs
sudo cp ~/Downloads/app.dimaginaxal.test*.pem /opt/homebrew/etc/nginx/certs/
sudo chmod 600 /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test-key.pem
sudo cp config/phase2/nginx-standby.conf /opt/homebrew/etc/nginx/nginx.conf
sudo nginx -t && sudo nginx
```

On an Intel Mac, replace `/opt/homebrew` with `/usr/local` in the commands **and** inside the config.

Test the standby directly, before any DNS change, by pinning the name to Mac 3 for one request:

```bash
curl -sI --resolve app.dimaginaxal.test:443:10.7.27.218 https://app.dimaginaxal.test/api/status | grep -i x-edge
# x-edge: mac3-standby
```

**E.3 Two clients, watching.**

- **Mac 4 (Viraj): "cached" client.** Make a request now so the old answer sits in the cache, then watch:

  ```bash
  while true; do printf "%s " "$(date +%T)"; curl -s -D - -o /dev/null https://app.dimaginaxal.test/api/status | grep -i x-edge; sleep 2; done
  ```
- **Mac 2 or Mac 1: "new" client.** Its cache gets flushed right after the switch.

**E.4 The cutover.** Mac 1 (Sajjan) **and** Mac 3 (Sibtain) change both records in their dnsmasq config, then restart dnsmasq:

```
address=/app.dimaginaxal.test/10.7.27.218
address=/api.dimaginaxal.test/10.7.27.218
```

**E.5 Observe:**

- The new client: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder; curl -sI https://app.dimaginaxal.test/api/status | grep -i x-edge` shows **mac3-standby** right away.
- The cached client (Mac 4) keeps printing **mac2-primary** for up to 30 s, then switches to **mac3-standby**.
- Keep Mac 2's nginx **running** throughout. The old edge still serves the clients whose cache hasn't expired. That is how real migrations drain traffic.

**E.6 Revert:** set both records back to `10.7.29.80` on both DNS servers, restart dnsmasq, `sudo nginx -s stop` on Mac 3, and delete the copied key from Mac 3.

---

## Part 7: Extension F, Faculty-injected fault (everyone)

On the day, the faculty breaks one thing. **Say every step out loud.** Partial marks are given for method. Run:

```bash
./scripts/diagnose.sh                       # from Mac 4 (client)
./scripts/diagnose.sh                       # again ON Mac 2: section 6 then tests the backends directly
```

It checks in order: **DNS → IP → TCP → TLS → HTTP → backends**, and stops at the first broken layer.

Manual commands for each layer:

| Layer | Command | Healthy result |
| --- | --- | --- |
| DNS | `dig app.dimaginaxal.test` | `10.7.29.80`, SERVER = 10.7.12.240 or 10.7.27.218 |
| IP | `ping 10.7.29.80` | replies |
| TCP | `nc -vz app.dimaginaxal.test 443` | `succeeded` |
| TLS | `curl -v https://app.dimaginaxal.test 2>&1 \| grep -E "SSL\|subject\|verify"` | TLSv1.3, verify ok |
| HTTP | `curl -sI https://app.dimaginaxal.test/api/status` | 200, X-Backend |
| Backends (on Mac 2) | `curl http://10.7.27.218:3001/api/status` | JSON |

Practise these likely faults. Take turns injecting them on each other:

| Injected fault | Symptom | Layer | Fix |
| --- | --- | --- | --- |
| dnsmasq stopped on both Macs | dig times out | DNS | start dnsmasq |
| Wrong IP in `address=` | dig answers but the IP is wrong; curl times out or hits the wrong host | DNS (data) | fix the record, restart |
| Client DNS set to 8.8.8.8 | NXDOMAIN | DNS (client config) | `networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218` |
| nginx stopped | `nc` refused on 443 | TCP | `sudo nginx` |
| nginx `listen` changed to another port | refused on 443 | TCP | fix `listen`, reload |
| Certificate swapped or wrong `server_name` / SAN | curl error 60 | TLS | restore cert, reload |
| CA removed from keychain | curl error 60 "unable to get local issuer" | TLS (client trust) | re-add rootCA.pem |
| Wrong upstream port in nginx | 502 (or only one backend answers) | App / upstream | fix upstream, reload |
| Backend bound to `127.0.0.1` | 502 for that backend, works locally on the Mac | App / socket | bind `0.0.0.0` |
| pf blocking Mac 2 | 502 or timeout for that backend | Transport (firewall) | `sudo pfctl -f /etc/pf.conf` |

---

## Part 8: Evidence and the Phase 2 report

Save everything to `evidence/phase2/`, named so it can be found in 30 seconds:

```
00-ping-all-pairs.png        A5-dns-failover-dig.png      B-ttl-watcher.png
01-curl-v-full.txt           A6-dns-vs-app-failure.png    B-flush.png
02-304-not-modified.png      C-before.png C-after.png C-rollback.png
03-full-flow.pcapng          D-only-B.png D-recovered.png D-502.png
                             E-cutover-two-clients.png    F-practice-runs.png
```

The **Phase 2 report** (`docs/`, 5 marks) must cover:

1. What changed since Phase 1: the file list at the top of this document.
2. Each test and its result: before / action / after, with a screenshot reference.
3. Troubleshooting findings: what you practised in Part 7 and what surprised you.
4. **One paragraph per extension** (A–F) on what you learned. Write it in your own words: it doubles as viva preparation.

Also update the README: add the demo video link and a Phase 2 section.

---

## Part 9: Final demo rehearsal (Section 8 of the spec)

Rehearse once end to end with a timer. Everyone should be able to explain **every** step, not just their own Mac.

| # | Step | Who drives | Command / what to show |
| --- | --- | --- | --- |
| 1 | Topology + IP table | Sachin | README diagram |
| 2 | All on LAN | all | ping loop from Part 0.4 |
| 3 | Resolve the name | Viraj | `dig app.dimaginaxal.test` |
| 4 | HTTPS by name, no warning | Viraj | browser padlock + `curl -v` |
| 5 | Load balancing | Viraj | A/B loop |
| 6 | Wireshark | Sachin | `full-flow.pcapng` |
| 7 | Caching | Sibtain | `curl -I` + 304 |
| 8 | Backend failure | Sibtain | Part 5 |
| 9 | DNS resilience | Sajjan | Part 2 failover + Part 3 TTL |
| 10 | Injected fault | all | Part 7 |
| 11 | Viva | each person | — |

Questions everyone should be able to answer:

- Why does the client never need the backend IPs?
- What is the difference between DNS resolution and the TCP/TLS connection that follows?
- Why does Wireshark show "Application Data" instead of HTTP?
- Why is there no Certificate packet in plain view under TLS 1.3?
- What does TTL 30 mean, and why did `dig` see the change before `curl` did?
- Why a timeout (not "refused") when pf blocks a port?
- What is still a single point of failure, and how would AWS remove it?
