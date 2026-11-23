# Demo Commands: Complete Sheet

Mac 1 = Sajjan `10.7.12.240` · Mac 2 = Sachin `10.7.29.80` · Mac 3 = Sibtain `10.7.27.218` · Mac 4 = Viraj `10.7.11.150`

Run everything from inside the repo folder (`cd dimaginaxal_section_C`).

---

## 0. Before anything (all 4 Macs)

```bash
git checkout main && git pull
ipconfig getifaddr en0                     # must match the IP above. If not, stop and update config/phase2/
scutil --dns | grep nameserver             # no 100.100.100.100. Quit Tailscale / VPN if present
for ip in 10.7.12.240 10.7.29.80 10.7.27.218 10.7.11.150; do ping -c 3 $ip | tail -2; done
```

Keep laptops plugged in (Wi-Fi power saving slowed us down).

---

## 1. Start the services, in this order

**Mac 1: primary DNS** (Terminal 1, leave running)
```bash
sudo dnsmasq -C config/phase2/dnsmasq-primary.conf -d
```

**Mac 3: backup DNS** (Terminal 1, leave running)
```bash
sudo "$(brew --prefix)/sbin/dnsmasq" -C config/phase2/dnsmasq-backup.conf -d
```

**Mac 3: Backend A** (Terminal 2, leave running)
```bash
cd backend-a && node server.js
```

**Mac 4: Backend B** (Terminal 1, leave running)
```bash
cd backend-b && node server.js
```

**Mac 2: edge nginx**
```bash
sudo cp config/phase2/nginx.conf /opt/homebrew/etc/nginx/nginx.conf
sudo nginx -t && (sudo nginx -s reload 2>/dev/null || sudo nginx)
```

**Check from Mac 2** that everything answers, before changing any client DNS:
```bash
dig @10.7.12.240 app.dimaginaxal.test +short     # 10.7.29.80
dig @10.7.27.218 app.dimaginaxal.test +short     # 10.7.29.80
curl http://10.7.27.218:3001/api/status          # {"backend":"A",...}
curl http://10.7.11.150:3002/api/status          # {"backend":"B",...}
```

**All client Macs (Mac 2, Mac 4, Mac 1): use our DNS servers**
```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
```

**Mac 2 (second terminal): edge log**, keep open during the demo
```bash
tail -f /opt/homebrew/var/log/nginx/edge.log
```

---

## 2. Final demo, steps 1–11 (spec Section 8)

**Step 1: Topology.** Open `docs/Private Network Service Platform — Phase 2 Report.pdf`, Section 2.

**Step 2: All on the LAN** (every Mac)
```bash
ipconfig getifaddr en0
for ip in 10.7.12.240 10.7.29.80 10.7.27.218 10.7.11.150; do ping -c 2 $ip | tail -2; done
```

**Step 3: Resolve the private name** (Mac 4)
```bash
dig app.dimaginaxal.test              # answer 10.7.29.80, TTL 30, SERVER 10.7.12.240, flag aa
dig @8.8.8.8 app.dimaginaxal.test     # NXDOMAIN: the name is private
```

**Step 4: HTTPS by name, no warnings** (Mac 4)
```bash
curl -v https://app.dimaginaxal.test/api/status 2>&1 | grep -E "Connected to|SSL connection|ALPN|subject|issuer|verify ok|HTTP/2|x-edge"
open https://app.dimaginaxal.test     # browser padlock
```

**Step 5: Load balancing** (Mac 4)
```bash
for i in 1 2 3 4 5 6; do curl -s https://app.dimaginaxal.test/api/status; echo; done
for i in 1 2 3 4; do curl -s -D - -o /dev/null https://app.dimaginaxal.test/api/status | grep -i x-backend; done
```

**Step 6: Wireshark.** Open the saved capture (section 4 below), filter `dns || tcp.port == 443`.

**Step 7: Caching** (Mac 4)
```bash
curl -sI https://app.dimaginaxal.test/api/status | grep -iE "^HTTP|cache-control|etag|date|x-backend"
curl -sI https://app.dimaginaxal.test/api/info | grep -i etag
curl -sI -H 'If-None-Match: "55d7f080e5780b68"' https://app.dimaginaxal.test/api/info | head -1    # HTTP/2 304
curl -sI -H 'If-None-Match: "wrong"' https://app.dimaginaxal.test/api/info | head -1               # HTTP/2 200
curl -sI --http1.1 https://app.dimaginaxal.test/api/status | head -1                                # HTTP/1.1 200
```

**Step 8: Fail one backend.** Mac 4 runs the watcher:
```bash
while true; do curl -s https://app.dimaginaxal.test/api/status; echo "  $(date +%T)"; sleep 1; done
```
- Mac 3: **Ctrl+C** Backend A. The watcher shows only B, and the edge log shows `upstream_status=502, 200`.
- Mac 3: `node server.js` again. Within about 10 s, A and B alternate again.
- Optional: Mac 4 also stops Backend B, and you get `502 Bad Gateway`. Restart both.

**Step 9: Phase 2 DNS resilience.** See section 3 (A, B or E).

**Step 10: Injected fault** (any Mac)
```bash
./scripts/diagnose.sh
```

**Step 11: Viva.** See `docs/VIVA_GUIDE.md`.

---

## 3. Phase 2 extension demos

### A. Backup DNS
```bash
# Mac 4
dig app.dimaginaxal.test | grep -E "SERVER|10.7"          # SERVER 10.7.12.240
# Mac 1: Ctrl+C dnsmasq
# Mac 4
dig app.dimaginaxal.test | grep -E "SERVER|10.7"          # SERVER 10.7.27.218
curl -s https://app.dimaginaxal.test/api/status           # still works
# Mac 1: restart
sudo dnsmasq -C config/phase2/dnsmasq-primary.conf -d
```

DNS failure vs app failure:
```bash
# stop BOTH dnsmasq (Mac 1 + Mac 3), then on Mac 4:
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
curl -sS https://app.dimaginaxal.test/api/status          # curl: (6) Could not resolve host
# restart both DNS, stop BOTH backends, then:
dig app.dimaginaxal.test +short                           # 10.7.29.80 (DNS fine)
curl -s https://app.dimaginaxal.test/api/status           # 502 Bad Gateway
# restart everything
```

### B. TTL and record change
```bash
# Mac 4: watcher
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
while true; do printf "%s  " "$(date +%T)"; dscacheutil -q host -a name ttl.dimaginaxal.test | awk '/ip_address/{print $2}'; sleep 3; done
```
```bash
# Mac 1 (Sajjan)
sed -i '' 's#ttl.dimaginaxal.test/10.7.29.80#ttl.dimaginaxal.test/10.7.11.150#' config/phase2/dnsmasq-primary.conf
# Mac 3 (Sibtain)
sed -i '' 's#ttl.dimaginaxal.test/10.7.29.80#ttl.dimaginaxal.test/10.7.11.150#' config/phase2/dnsmasq-backup.conf
# both: Ctrl+C dnsmasq and start it again
```
```bash
# Mac 4, second terminal
dig ttl.dimaginaxal.test +short      # new IP at once (dig skips the cache)
# the watcher switches within 30 s
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder    # or switch immediately
```
Revert (Mac 1 and Mac 3), then restart dnsmasq:
```bash
git checkout config/phase2/dnsmasq-primary.conf     # Mac 1
git checkout config/phase2/dnsmasq-backup.conf      # Mac 3
```

### C. Firewall isolation (Mac 3 and Mac 4)
```bash
# Before. Mac 1 can reach both:
curl --connect-timeout 5 http://10.7.27.218:3001/api/status
curl --connect-timeout 5 http://10.7.11.150:3002/api/status
```
```bash
# Mac 3 and Mac 4: save rollback copy
sudo pfctl -s info | head -1 > ~/pf-status-before.txt
sudo pfctl -sr > ~/pf-rules-before.txt
cp /etc/pf.conf ~/pf.conf.backup
# load
sudo pfctl -f config/phase2/pf-backend-a.conf && sudo pfctl -e     # Mac 3
sudo pfctl -f config/phase2/pf-backend-b.conf && sudo pfctl -e     # Mac 4
sudo pfctl -sr                                                     # show rules
```
```bash
# After
curl --connect-timeout 5 http://10.7.27.218:3001/api/status   # Mac 1: timeout
curl --connect-timeout 5 http://10.7.11.150:3002/api/status   # Mac 1: timeout
ping -c 3 10.7.27.218                                         # Mac 1: still works
curl http://10.7.27.218:3001/api/status                       # Mac 2: works (edge allowed)
curl -s https://app.dimaginaxal.test/api/status               # any client: works via edge
```
```bash
# Roll back (Mac 3 and Mac 4)
cat ~/pf-status-before.txt
sudo pfctl -f /etc/pf.conf
sudo pfctl -d              # only if the file said "Disabled"
```

### D. Failover
Same as final demo Step 8.

### E. DNS-based edge cutover
Mac 3 needs nginx and the certificate files once. On **Mac 2**:
```bash
mkdir -p ~/Desktop/certs-for-sibtain
sudo /bin/cp /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test.pem /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test-key.pem ~/Desktop/certs-for-sibtain/
sudo chown $USER ~/Desktop/certs-for-sibtain/*
# AirDrop both files to Sibtain
```
**Mac 3:**
```bash
brew install nginx
sudo mkdir -p /opt/homebrew/etc/nginx/certs
sudo cp ~/Downloads/app.dimaginaxal.test*.pem /opt/homebrew/etc/nginx/certs/
sudo chmod 600 /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test-key.pem
sudo cp config/phase2/nginx-standby.conf /opt/homebrew/etc/nginx/nginx.conf
sudo nginx -t && (sudo nginx -s reload 2>/dev/null || sudo nginx)
```
**Mac 2:** test the standby without DNS
```bash
curl -sI --resolve app.dimaginaxal.test:443:10.7.27.218 https://app.dimaginaxal.test/api/status | grep -iE "^HTTP|x-edge"
```
**Mac 4:** cached-client watcher (start before the switch)
```bash
while true; do printf "%s " "$(date +%T)"; curl -s -D - -o /dev/null https://app.dimaginaxal.test/api/status | grep -i x-edge; sleep 2; done
```
**Mac 1 and Mac 3:** switch the record, then restart dnsmasq
```bash
sed -i '' -e 's#app.dimaginaxal.test/10.7.29.80#app.dimaginaxal.test/10.7.27.218#' -e 's#api.dimaginaxal.test/10.7.29.80#api.dimaginaxal.test/10.7.27.218#' config/phase2/dnsmasq-primary.conf   # Mac 1
sed -i '' -e 's#app.dimaginaxal.test/10.7.29.80#app.dimaginaxal.test/10.7.27.218#' -e 's#api.dimaginaxal.test/10.7.29.80#api.dimaginaxal.test/10.7.27.218#' config/phase2/dnsmasq-backup.conf    # Mac 3
```
**Mac 2:** new client
```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
curl -sI https://app.dimaginaxal.test/api/status | grep -i x-edge      # mac3-standby
```
Keep Mac 2's nginx running. Mac 4 switches from mac2-primary to mac3-standby within 30 s.

**Revert:**
```bash
git checkout config/phase2/dnsmasq-primary.conf     # Mac 1, then restart dnsmasq
git checkout config/phase2/dnsmasq-backup.conf      # Mac 3, then restart dnsmasq
sudo nginx -s stop                                  # Mac 3
sudo rm /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test-key.pem ~/Downloads/app.dimaginaxal.test-key.pem   # Mac 3
rm -rf ~/Desktop/certs-for-sibtain                  # Mac 2
```

---

## 4. Wireshark / packet capture (Mac 4 as the client)

**GUI:** Wireshark → interface `en0` → start. Then:
```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder    # forces a real DNS query
curl -s https://app.dimaginaxal.test/api/status
```
Stop, then **File → Save As** `evidence/phase2/full-flow.pcapng`.

**Or from the terminal:**
```bash
sudo tcpdump -i en0 -w evidence/phase2/full-flow.pcap 'port 53 or port 443' &
sleep 1; sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
curl -s https://app.dimaginaxal.test/api/status; sleep 2; sudo kill %1
```

Filters to show:

| Filter | Shows |
| --- | --- |
| `dns && dns.qry.name contains "dimaginaxal"` | Query + answer A 10.7.29.80 |
| `ip.addr == 10.7.29.80 && tcp.flags.syn == 1` | SYN and SYN-ACK to :443 |
| `tls.handshake.type == 1` | ClientHello (open it → Server Name = app.dimaginaxal.test) |
| `ip.addr == 10.7.29.80 && tls` | Handshake, then Application Data only |
| `tcp.port == 3001 \|\| tcp.port == 3002` | nginx → backend, readable HTTP (capture on **Mac 2**) |

---

## 5. Fault-injection practice (Extension F)

One person breaks something, another runs `./scripts/diagnose.sh` and explains it out loud.

| # | Who breaks it | Break | Expected symptom | Fix |
| --- | --- | --- | --- | --- |
| 1 | Mac 1 + Mac 3 | Ctrl+C both dnsmasq | `curl: (6)` / dig timeout → **DNS** | Start both again |
| 2 | Mac 1 + Mac 3 | `sed -i '' 's#app.dimaginaxal.test/10.7.29.80#app.dimaginaxal.test/10.7.11.150#' config/phase2/dnsmasq-*.conf`, restart | dig answers the **wrong IP**, curl refused on 443 → **DNS data** | `git checkout config/phase2/`, restart |
| 3 | Mac 4 (client) | `sudo networksetup -setdnsservers Wi-Fi 8.8.8.8` | NXDOMAIN → **DNS client config** | `sudo networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218` |
| 4 | Mac 2 | `sudo nginx -s stop` | dig fine, ping fine, `curl: (7)` refused → **TCP** | `sudo nginx` |
| 5 | Mac 2 | `sudo sed -i '' 's/10.7.11.150:3002/10.7.11.150:3005/' /opt/homebrew/etc/nginx/nginx.conf && sudo nginx -s reload` | Only A answers (B "down") → **upstream config** | `sudo cp config/phase2/nginx.conf /opt/homebrew/etc/nginx/nginx.conf && sudo nginx -s reload` |
| 6 | Mac 3 + Mac 4 | Ctrl+C both backends | **502** → **application** | Restart both |
| 7 | Mac 3 | `sed 's/10.7.29.80/10.7.12.240/' config/phase2/pf-backend-a.conf > /tmp/pf-bad.conf && sudo pfctl -f /tmp/pf-bad.conf && sudo pfctl -e` | Only B answers; Mac 2 → :3001 times out → **firewall** | `sudo pfctl -f /etc/pf.conf` |
| 8 | anyone | `curl https://app.dimaginaxal.test:9999` | `curl: (7)` refused, but ping works → **wrong port** | Use 443 |
| 9 | anyone | `curl https://10.7.29.80/api/status` | `curl: (60)` certificate name mismatch → **TLS** | Use the name, never the IP |

Manual layer checks:
```bash
dig app.dimaginaxal.test                                              # DNS
ping -c 2 10.7.29.80                                                  # IP
nc -vz app.dimaginaxal.test 443                                       # TCP
curl -v https://app.dimaginaxal.test 2>&1 | grep -E "SSL|subject|verify"   # TLS
curl -sI https://app.dimaginaxal.test/api/status | head -1            # HTTP
curl http://10.7.27.218:3001/api/status                               # backend (run on Mac 2)
curl http://10.7.11.150:3002/api/status
```

---

## 6. Cleanup after the demo (important)

```bash
sudo networksetup -setdnsservers Wi-Fi empty      # every client Mac, or internet breaks once our DNS stops
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
sudo nginx -s stop                                # Mac 2 (and Mac 3 if the standby ran)
# Ctrl+C dnsmasq (Mac 1, Mac 3) and node (Mac 3, Mac 4)
sudo pfctl -f /etc/pf.conf                        # Mac 3, Mac 4, if firewall rules were loaded
git checkout config/phase2/                       # undo any record edits
```
