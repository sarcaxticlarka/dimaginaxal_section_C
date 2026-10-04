# Private Network Service Platform: Phase 1

Computer Networks course project. Four MacBooks on one Wi-Fi network run a small private service platform with our own DNS server, an nginx edge with HTTPS, and two backend servers behind it.

> The application stays simple; the network is the project.

**Demo video:** _add link here_  
**Phase 1 report (PDF):** [docs/](docs/)

---

## Team

| Member | Machine | Role | IP |
| --- | --- | --- | --- |
| Md. Sajjan | Mac 1 | Private DNS server (dnsmasq) + test client | 10.7.2.83 |
| Sachin Jaiswal | Mac 2 | Edge: nginx reverse proxy, load balancer, TLS | 10.7.1.138 |
| Sibtain Ahmed Qureshi | Mac 3 | Backend A (Node.js) | 10.7.12.144 |
| Viraj Chafale | Mac 4 | Backend B (Node.js) + test client | 10.7.16.85 |

Network: `10.7.0.0/19` (mask 255.255.224.0), gateway `10.7.0.1`, interface `en0` on all Macs.  
Domain: `app.dimaginaxal.test` and `api.dimaginaxal.test`. Both point to Mac 2.

We used `.test` because it is reserved for testing. `.local` clashes with macOS Bonjour (mDNS).

---

## How a request travels

```
Client (Mac 3 / Mac 4)
   │  1. DNS query, UDP 53
   ▼
Mac 1  dnsmasq ── answers app.dimaginaxal.test = 10.7.1.138
   │
   │  2. TCP handshake + TLS 1.3 to port 443
   ▼
Mac 2  nginx  (TLS ends here)
   │  3. plain HTTP, round-robin
   ├──────────────► Mac 3  Backend A :3001
   └──────────────► Mac 4  Backend B :3002
```

The client only knows the domain name. It never sees the backend addresses.

---

## Repository layout

```
├── README.md
├── docs/               Phase 1 report
├── config/
│   ├── dnsmasq.conf    Mac 1
│   ├── nginx.conf      Mac 2
│   └── TLS_SETUP.md    certificate steps and CA trust
├── backend-a/          server.js, package.json (Mac 3)
├── backend-b/          server.js, package.json (Mac 4)
├── scripts/            quick test scripts
└── evidence/           annotated screenshots
```

Private keys (`*-key.pem`) are excluded by `.gitignore` and are not in this repo.

---

## Running it

Start the services in this order: DNS, then the backends, then nginx.

### Mac 1: DNS

```bash
brew install dnsmasq
sudo dnsmasq -C config/dnsmasq.conf -d
```

Check from any Mac:

```bash
dig @10.7.2.83 app.dimaginaxal.test +short
# 10.7.1.138
```

Point each client at Mac 1 for DNS:

```bash
sudo networksetup -setdnsservers Wi-Fi 10.7.2.83
```

### Mac 3 and Mac 4: backends

```bash
cd backend-a && node server.js     # Mac 3, port 3001
cd backend-b && node server.js     # Mac 4, port 3002
```

Both listen on `0.0.0.0` so other machines can reach them. Check from another Mac:

```bash
curl -i http://10.7.12.144:3001/api/status
curl -i http://10.7.16.85:3002/api/status
```

### Mac 2: nginx

Create the certificate first (see [config/TLS_SETUP.md](config/TLS_SETUP.md)), then:

```bash
brew install nginx
sudo cp config/nginx.conf /opt/homebrew/etc/nginx/nginx.conf
sudo nginx -t
sudo nginx            # or: sudo nginx -s reload
```

---

## Endpoints

| Request | Response |
| --- | --- |
| `GET /` | `{"message":"Dimaginaxal Backend A","backend":"A","status":"running"}` |
| `GET /api/status` | `{"backend":"A","status":"ok"}` (or `"B"`) |

Every response carries:

```
X-Backend: A            (or B)
Cache-Control: public, max-age=60
```

---

## Testing

**HTTPS with certificate checking on.** No `-k` flag.

```bash
curl -i https://app.dimaginaxal.test/api/status
```

**Load balancing.** Repeated requests alternate between the backends.

```bash
for i in 1 2 3 4 5 6; do curl -s https://app.dimaginaxal.test/api/status; echo; done
```

Our result:

```
{"backend":"A","status":"ok"}
{"backend":"B","status":"ok"}
{"backend":"A","status":"ok"}
{"backend":"B","status":"ok"}
{"backend":"A","status":"ok"}
{"backend":"B","status":"ok"}
```

**Caching header**

```bash
curl -I https://app.dimaginaxal.test/api/status
```

### Wireshark filters we used

| Filter | Shows |
| --- | --- |
| `dns` | DNS query and answer for our domain |
| `tls` | TLS handshake (ClientHello with SNI) |
| `tcp.port == 443` | Client to nginx connections |
| `tcp.port == 3001 \|\| tcp.port == 3002` | nginx to backend traffic |

---

## Phase 1 status

| Task | Status |
| --- | --- |
| A. Private LAN | Done |
| B. Private DNS | Done |
| C. Two backends | Done |
| D. Reverse proxy + load balancing | Done |
| E. HTTPS / TLS | Done (CA trust shown on Mac 2 and Mac 3) |
| F. HTTP caching | Partly: Cache-Control header shown; 304 / cache hit still to demonstrate |
| G. Packet capture | Partly: DNS and nginx-to-backend captured; clean client-to-443 handshake still to add |

Phase 2 (backup DNS, TTL changes, firewall isolation, failover, DNS cutover) comes next.