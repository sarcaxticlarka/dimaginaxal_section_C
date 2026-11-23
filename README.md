# Private Network Service Platform

Computer Networks course project, team **dimaginaxal** (Section C). Four MacBooks on one Wi-Fi network run a small private service platform: our own DNS servers, an nginx edge with HTTPS and load balancing, and two backend servers behind it. Phase 2 added backup DNS, short TTLs, firewall isolation, backend failover and a DNS-based edge cutover.

> The application stays simple; the network is the project.

| | Phase 1: Build & Observe | Phase 2: Harden & Recover |
| --- | --- | --- |
| Report | [Phase 1 Report (PDF)](docs/Private%20Network%20Service%20Platform%20%E2%80%94%20Phase%201%20Report.pdf) | [Phase 2 Report (PDF)](docs/Private%20Network%20Service%20Platform%20%E2%80%94%20Phase%202%20Report.pdf) |
| Demo video | [Google Drive](https://drive.google.com/file/d/1Huvf7k8NavVsH3BzQi5_YMy50qb1eF0k/view) | _add link_ |
| Configs | [`config/`](config/) | [`config/phase2/`](config/phase2/) |
| Evidence | [`evidence/`](evidence/) | [`evidence/phase2/`](evidence/phase2/) |
| Instructions | this README | [Phase 2 runbook](docs/PHASE2_RUNBOOK.md) |

---

## Team

| Member | Enrolment | Machine | Role | IP (Phase 2) |
| --- | --- | --- | --- | --- |
| Md. Sajjan | 2401010272 | Mac 1 | Primary DNS (dnsmasq) + test client | 10.7.12.240 |
| Sachin Jaiswal | 2401010399 | Mac 2 | Edge: nginx reverse proxy, load balancer, TLS | 10.7.29.80 |
| Sibtain Ahmed Qureshi | 2401010454 | Mac 3 | Backend A (Node.js), backup DNS, standby edge | 10.7.27.218 |
| Viraj Chafale | 2401020076 | Mac 4 | Backend B (Node.js) + main test client | 10.7.11.150 |

Network: `10.7.0.0/19` (mask 255.255.224.0, hosts 10.7.0.1–10.7.31.254), gateway `10.7.0.1`, interface `en0` on all Macs.
Domain: `app.dimaginaxal.test` and `api.dimaginaxal.test`, both pointing to the edge (Mac 2).

The Wi-Fi hands out addresses by DHCP. In Phase 1 the Macs were 10.7.2.83, 10.7.1.138, 10.7.12.144 and 10.7.16.85, and the files in `config/` still use those. **Always check `ipconfig getifaddr en0` before a demo.** If an address has changed, update `config/phase2/` first.

We use `.test` because it is reserved for testing and never exists on the public internet. `.local` would clash with macOS Bonjour (mDNS).

---

## How a request travels

```
Client (Mac 4)
   │  1. DNS query, UDP 53  ──►  Mac 1 dnsmasq (primary)   ─┐  same records,
   │                             Mac 3 dnsmasq (backup)    ─┘  TTL 30 s
   │  ◄── app.dimaginaxal.test = 10.7.29.80
   │
   │  2. TCP handshake + TLS 1.3 (+ HTTP/2) to port 443
   ▼
Mac 2  nginx 10.7.29.80  (TLS ends here, X-Edge: mac2-primary)
   │  3. plain HTTP, round-robin, retries the other backend if one fails
   ├──────────────► Mac 3  Backend A  10.7.27.218:3001   ┐ pf: only Mac 2
   └──────────────► Mac 4  Backend B  10.7.11.150:3002   ┘ may connect
```

The client only knows the domain name. It never sees the backend addresses.

---

## Repository layout

```
├── README.md
├── backend-a/              server.js (Mac 3, port 3001)
├── backend-b/              server.js (Mac 4, port 3002)
├── config/
│   ├── dnsmasq.conf        Phase 1 DNS (old IPs)
│   ├── nginx.conf          Phase 1 edge (old IPs)
│   ├── TLS_SETUP.md        certificate creation and CA trust
│   └── phase2/
│       ├── dnsmasq-primary.conf   Mac 1
│       ├── dnsmasq-backup.conf    Mac 3
│       ├── nginx.conf             Mac 2 (failover, X-Edge, HTTP/2)
│       ├── nginx-standby.conf     Mac 3 (standby edge)
│       ├── pf-backend-a.conf      Mac 3 firewall
│       └── pf-backend-b.conf      Mac 4 firewall
├── scripts/
│   ├── test-dns.sh, test-lb.sh, test-cache.sh
│   └── diagnose.sh         layer-by-layer troubleshooting
├── docs/
│   ├── Phase 1 and Phase 2 report PDFs
│   ├── PHASE2_RUNBOOK.md   step-by-step for every Mac
│   ├── PHASE2_REPORT.md    report text
│   ├── VIVA_GUIDE.md       what to study + likely questions
│   └── src/                HTML source + build script for the Phase 2 PDF
└── evidence/               Phase 1 screenshots; evidence/phase2/ for Phase 2
```

Private keys (`*-key.pem`) are excluded by `.gitignore` and are never committed.

---

## Running it (Phase 2 setup)

Start in this order: **DNS → backends → nginx**, then test from a client. The [runbook](docs/PHASE2_RUNBOOK.md) has every demo step.

**Mac 1 (primary DNS)**
```bash
brew install dnsmasq
sudo dnsmasq -C config/phase2/dnsmasq-primary.conf -d
```

**Mac 3 (Backend A + backup DNS)**, in two terminals:
```bash
cd backend-a && node server.js
```
```bash
sudo "$(brew --prefix)/sbin/dnsmasq" -C config/phase2/dnsmasq-backup.conf -d
```

**Mac 4 (Backend B)**
```bash
cd backend-b && node server.js
```

**Mac 2 (edge)**: create the certificate first ([config/TLS_SETUP.md](config/TLS_SETUP.md)), then:
```bash
sudo cp config/phase2/nginx.conf /opt/homebrew/etc/nginx/nginx.conf
sudo nginx -t && (sudo nginx -s reload 2>/dev/null || sudo nginx)
```

**Every client**: use both DNS servers and trust our CA (`rootCA.pem` from Mac 2):
```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.12.240 10.7.27.218
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/Downloads/rootCA.pem
```

To undo the DNS setting afterwards (otherwise the Mac loses internet once our DNS servers stop): `sudo networksetup -setdnsservers Wi-Fi empty`

---

## Endpoints

| Request | Response |
| --- | --- |
| `GET /` | `{"message":"Dimaginaxal Backend A","backend":"A","status":"running"}` |
| `GET /api/status` | `{"backend":"A","status":"ok"}` (or `"B"`) |
| `GET /api/info` | `{"service":"dimaginaxal","version":"phase-2"}`: the same on A and B, so the ETag matches whichever backend answers |

Headers on every response:

```
X-Backend: A                      (or B, set by the backend)
Cache-Control: public, max-age=60
ETag: "<hash of the body>"        (If-None-Match with this value returns 304)
X-Edge: mac2-primary              (or mac3-standby, set by nginx)
```

---

## Testing

```bash
# HTTPS with certificate checking on (never -k)
curl -v https://app.dimaginaxal.test/api/status

# Load balancing: A and B alternate
for i in 1 2 3 4 5 6; do curl -s https://app.dimaginaxal.test/api/status; echo; done

# Caching: 200 with an ETag, then 304 when we send it back
curl -sI https://app.dimaginaxal.test/api/info | grep -i etag
curl -sI -H 'If-None-Match: "55d7f080e5780b68"' https://app.dimaginaxal.test/api/info | head -1

# Something broken? Check layer by layer
./scripts/diagnose.sh
```

### Wireshark filters

| Filter | Shows |
| --- | --- |
| `dns` | DNS query and answer for our domain |
| `tcp.flags.syn == 1 && tcp.port == 443` | Connection openings to nginx |
| `tls` | TLS handshake (ClientHello with SNI) |
| `dns \|\| tcp.port == 443` | One full request: DNS → TCP → TLS → data |
| `tcp.port == 3001 \|\| tcp.port == 3002` | nginx to backend traffic (plain HTTP) |

---

## Status

| Item | Status |
| --- | --- |
| Phase 1, Tasks A–E (LAN, DNS, backends, load balancing, TLS) | Done |
| Phase 1, Task F (caching) | Done: Cache-Control, ETag, 304 shown in Phase 2 |
| Phase 1, Task G (packet capture) | DNS, TCP and TLS captured; a clean client → :443 capture is still to add |
| Phase 2, A. Backup DNS | Done |
| Phase 2, B. TTL and record change | Done |
| Phase 2, C. Firewall isolation (pf) | Done, rolled back after the demo |
| Phase 2, D. Backend failover | Done |
| Phase 2, E. DNS-based edge cutover | Done |
| Phase 2, F. Troubleshooting | Method and script ready; practice runs to record |

Remaining evidence is listed in Section 11 of the Phase 2 report.
