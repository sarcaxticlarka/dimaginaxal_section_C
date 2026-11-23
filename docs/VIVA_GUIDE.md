# Viva Guide: What to Study

The examiner can ask **anyone about any part**. The spec says answers must come "from personal understanding, not from reading notes". So the goal is not to memorise answers but to be able to **explain the flow in your own words, using our own IPs and our own evidence**.

How to use this guide:

1. Learn **the story** in Part 1 until you can tell it in two minutes without notes.
2. Study the topics in Part 2, one layer at a time.
3. Test yourself with the questions in Part 3. Cover the answer and say yours out loud first.
4. Rehearse the demo in Part 4 with the team.

---

## Part 1: The story of one request (learn this first)

Everything else hangs off this. Say it while pointing at the topology diagram.

> Viraj's Mac types `https://app.dimaginaxal.test/api/status`.
>
> **1. DNS.** The Mac doesn't know the IP, so it sends a **DNS query over UDP to port 53** at our primary DNS server, Mac 1 (10.7.12.240). dnsmasq has a record `address=/app.dimaginaxal.test/10.7.29.80`, so it answers **A 10.7.29.80 with TTL 30**. The client caches this for 30 seconds. If Mac 1 is down, the client asks the backup on Mac 3 (10.7.27.218), which holds the same records.
>
> **2. ARP.** 10.7.29.80 is in the same /19 subnet, so the client sends the frame **directly** to Mac 2, not to the router. It uses ARP to learn Mac 2's MAC address first.
>
> **3. TCP.** The client opens a connection from a random **ephemeral port** (e.g. 54821) to **10.7.29.80:443**: SYN → SYN-ACK → ACK. Now there's a reliable, ordered byte stream.
>
> **4. TLS 1.3.** The client sends a **ClientHello** (TLS versions, cipher suites, key share, and **SNI = app.dimaginaxal.test**). nginx replies with a **ServerHello** and its key share. From here everything is encrypted: nginx sends its **certificate**, signed by our mkcert CA, and proves it owns the private key. The client checks that the certificate chains to a CA in its keychain, that the name matches the SAN, and that it hasn't expired. Both sides send **Finished**. One round trip. ALPN picks **HTTP/2**.
>
> **5. HTTP.** Inside the encrypted channel the client sends `GET /api/status`. Wireshark sees only "Application Data".
>
> **6. Load balancing.** nginx **terminates TLS**, picks the next backend in **round-robin** order, and opens a **plain HTTP** connection to Backend A (10.7.27.218:3001) or B (10.7.11.150:3002). The backends' firewall only lets Mac 2 in.
>
> **7. Response.** The backend returns `200` with `X-Backend: A`, `Cache-Control: public, max-age=60` and an `ETag`. nginx adds `X-Edge: mac2-primary`, encrypts it, and sends it back.
>
> **If a backend is dead**, nginx gets "connection refused", marks it down for 10 s, and **retries the same request on the other one**. The client still gets 200. **If both are dead**, nginx answers 502 Bad Gateway itself.

**Layer map**, which you'll be asked to draw:

| TCP/IP layer | OSI | In our project |
| --- | --- | --- |
| Application | 7 (TLS ≈ 5–6) | DNS, HTTP/1.1 and HTTP/2, TLS 1.3 wrapping HTTP |
| Transport | 4 | UDP 53 (DNS); TCP 443, 3001, 3002 |
| Internet | 3 | IPv4, all hosts in 10.7.0.0/19 |
| Link | 2, 1 | Wi-Fi frames with MAC addresses (Wireshark shows "Ethernet II"), ARP |

---

## Part 2: Topics to study

For each topic: the concepts, then **how it shows up in our project**. Our version of each answer is what scores marks.

### 2.1 IP addressing and the LAN

- **IP address, subnet mask, prefix.** /19 = 255.255.224.0. Our range is 10.7.0.0 – 10.7.31.255, with 8,190 usable hosts. Our four IPs look far apart (third octet 11, 12, 27, 29) but all fall below 32, so they're in one subnet.
- **Gateway** (10.7.0.1): used only for destinations *outside* the subnet. In the Phase 1 Wireshark capture, DNS frames went straight to Mac 1's MAC, but internet traffic went to the router's MAC (RuckusWireless).
- **MAC address and ARP**: IP finds the host, MAC delivers the frame on the local link. ARP maps an IP to a MAC.
- **DHCP**: why our IPs changed between Phase 1 and Phase 2. Real infrastructure uses static or reserved addresses.
- **ping / ICMP**: tests reachability at the IP layer only. It says nothing about ports.

### 2.2 DNS (Mac 1 and Mac 3)

- **What DNS is**: a directory that turns names into IPs. It does **not** carry the connection itself.
- **Records**: A (IPv4), AAAA (IPv6), CNAME, NS, SOA. We use A records.
- **Authoritative vs recursive**: dnsmasq is **authoritative** for our names (the `aa` flag in dig) and **forwards** everything else to 1.1.1.1 / 8.8.8.8 (`server=` lines).
- **Our config lines**: `listen-address` (must include the LAN IP, not just 127.0.0.1, or other Macs can't use it), `bind-interfaces`, `no-resolv` (don't read /etc/resolv.conf), `local-ttl=30`.
- **TTL**: how long a resolver may cache an answer. Phase 1 used 0 (never cached), Phase 2 uses 30.
- **`dig` vs applications**: `dig` asks the server directly. curl and browsers go through the **macOS cache** (mDNSResponder), which honours the TTL. That's why dig saw a change instantly while curl waited up to 30 s.
- **Flushing**: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.
- **Why `.test`**: reserved (RFC 2606), never real. `.local` belongs to mDNS/Bonjour.
- **NXDOMAIN**: "this name does not exist". `dig @8.8.8.8 app.dimaginaxal.test` proves the name is private.
- **Backup DNS**: clients have a list of servers. If one doesn't answer, they ask the next. The risk is the two servers holding **different** records.

### 2.3 TCP and UDP (transport)

- **UDP**: connectionless, no handshake, no retransmission. Good for small DNS queries.
- **TCP**: connection-oriented, reliable, ordered. Used for HTTPS and for nginx → backends.
- **3-way handshake**: SYN (seq = x) → SYN-ACK (seq = y, ack = x+1) → ACK (ack = y+1). Wireshark shows relative numbers: Seq=0, then Ack=1.
- **Ports**: well-known server ports (53, 443, 3001, 3002) vs the client's random **ephemeral** port. **Socket pair** = src IP, src port, dst IP, dst port. That's how one Mac holds many connections at once.
- **Reliability**: sequence and acknowledgement numbers, retransmission, **duplicate ACKs** (seen in our Phase 1 capture on Wi-Fi).
- **Flow control**: the receive **window** says how much data the sender may send before waiting for an ACK.
- **Refused vs timeout**: *refused* means the host replied with a RST because nothing listens on that port. *Timeout* means nothing came back at all: a firewall dropped the packet, or the host is gone.

### 2.4 TLS / HTTPS (Mac 2, Sachin's part, but everyone must know it)

- **Why TLS**: confidentiality (encryption), integrity, authentication (the certificate proves who the server is).
- **TLS 1.3 handshake**: ClientHello → ServerHello → (encrypted from here) EncryptedExtensions, **Certificate**, CertificateVerify, Finished → client Finished → Application Data. One round trip.
- **Why there's no plaintext Certificate packet in our capture**: TLS 1.3 encrypts the certificate. TLS 1.2 sent it in the clear. The ChangeCipherSpec you may see in 1.3 is only there for compatibility with older middleboxes.
- **SNI**: the hostname in the ClientHello, sent in plaintext. It tells nginx which certificate to present.
- **Certificate checks**: (1) it chains to a **trusted CA**, here our mkcert root CA in the System keychain; (2) the **name matches the SAN** (`app.dimaginaxal.test`); (3) the dates are valid; (4) the server proves it owns the private key (CertificateVerify).
- **mkcert**: creates a local CA. `rootCA.pem` is public and goes to every client. `rootCA-key.pem` **must never leave Mac 2**: anyone with it could sign fake certificates our Macs would trust.
- **TLS termination**: nginx decrypts. Edge → backend is plain HTTP inside the LAN. That's common, because it saves CPU and keeps certificates in one place. For stricter setups you'd re-encrypt the backend hop as well (mTLS).
- **Why no `-k`**: `-k` turns off certificate verification, so you'd prove nothing. The real problem we fixed was **trust**: Mac 3 and Mac 4 had to import our CA.
- **The certificate is bound to the name, not the IP**: that's why the standby edge on Mac 3 could use the same certificate.

### 2.5 HTTP, REST and caching

- **Request / response**, methods (GET), headers, status codes: **200** OK, **301** redirect (our port 80 → 443), **304** Not Modified, **404** Not Found (our `/api/status;` typo), **502** Bad Gateway (upstream refused or failed), **504** Gateway Timeout (upstream too slow).
- **REST**: resources accessed by URL with standard methods, stateless, JSON here.
- **HTTP/1.1 vs HTTP/2 vs HTTP/3**: 1.1 is text, with one request at a time per connection. 2 is binary framing, **multiplexes** many requests on one connection, and compresses headers (HPACK); TLS's ALPN picks it. 3 runs over **QUIC on UDP** and avoids TCP head-of-line blocking (explanation only).
- **Caching**: `Cache-Control: public, max-age=60` means any cache may reuse the response for 60 s. `no-cache` means revalidate every time; `no-store` means never store it.
- **ETag / If-None-Match → 304**: a conditional request. "I have version X, is it still current?" If so: 304, headers only.
- **The three cases**: a fresh cache hit (no request at all), a conditional request (304), a full request (200 with the body).
- **Headers we use**: `X-Backend` (which backend answered), `X-Edge` (which edge answered), `X-Forwarded-For` / `X-Real-IP` (pass the real client IP to the backend, since otherwise it only sees nginx), `Host` (keeps the original hostname).

### 2.6 Reverse proxy and load balancing (Mac 2)

- **Reverse proxy**: one public entry point, with the backends hidden behind it. The client never knows the backend IPs, so we can add, remove or move backends without changing clients.
- **Round-robin**: the nginx default, taking each server in turn. Alternatives: `least_conn`, `ip_hash` (sticky sessions), weights.
- **Passive health checks**: `max_fails=1 fail_timeout=10s`. A backend that fails once is skipped for 10 s, then tried again.
- **Retry**: `proxy_next_upstream error timeout http_502 …` resends a failed request to the other backend. This is the `upstream_status=502, 200` line in our log.
- **Active health checks** (probing `/health` on a timer) need nginx Plus or a module. The cloud equivalent is ALB target-group health checks.
- **Single point of failure**: the edge itself. The fixes are a floating IP (VRRP/keepalived), DNS failover (Route 53), or a managed load balancer across availability zones.
- **Cloud mapping**: dnsmasq ≈ Route 53 private hosted zone, nginx ≈ ALB / CDN edge, the backends ≈ EC2 instances in a target group, pf ≈ security groups.

### 2.7 Firewall and isolation (Mac 3, Mac 4)

- **pf rules**: `pass in quick proto tcp from 10.7.29.80 to any port 3001`, then `block drop in quick … port 3001`. **`quick`** means the first matching rule wins. pf is **stateful** (`keep state`), so return traffic is allowed automatically.
- **Why `block drop`**: the client gets a timeout, which gives an attacker less information. `block return` sends a RST and the client sees "refused".
- **Ping still works**: ICMP isn't TCP port 3001. A firewall filters by protocol and port, not by host.
- **Rollback**: `sudo pfctl -f /etc/pf.conf`. Always keep a copy, because a bad rule can lock you out.
- **Defence in depth**: even if someone learns a backend IP, they can't reach it directly.

### 2.8 Troubleshooting method

Always go in this order and say each step out loud:

1. **DNS**: `dig app.dimaginaxal.test`. Is there an answer, from the right server, with the right IP?
2. **IP**: `ping 10.7.29.80`. Is the host reachable?
3. **TCP**: `nc -vz app.dimaginaxal.test 443`. Is something listening on the port?
4. **TLS**: `curl -v https://…`. Does the certificate verify?
5. **HTTP**: what status code comes back?
6. **Backend**: from Mac 2, `curl http://10.7.27.218:3001/api/status`.

**curl error codes** point straight at a layer: **6** = DNS, **7** = connection refused (TCP), **28** = timeout, **35** = TLS handshake failed, **60** = certificate not trusted. **502** = the edge is fine, a backend is the problem.

---

## Part 3: Likely viva questions

Cover the answer, answer out loud, then check.

### Basics and topology

| Question | Answer in short |
| --- | --- |
| Explain your topology. | Four Macs on one /19 Wi-Fi subnet: DNS (Mac 1), edge (Mac 2), Backend A plus backup DNS (Mac 3), Backend B plus client (Mac 4). Clients only ever talk to Mac 2. |
| Why are all four in one subnet when the IPs look so different? | A /19 spans 10.7.0.0 – 10.7.31.255. All our third octets are below 32. |
| Does traffic between your Macs go through the router? | No. Same subnet means direct delivery by MAC address (via ARP). Only internet traffic goes to the gateway. |
| What's the cloud equivalent of each machine? | Route 53, ALB / CDN edge, app instances; pf ≈ security groups. |
| Why `.test` and not `.local`? | `.test` is reserved and never real. `.local` is used by macOS mDNS/Bonjour, so lookups would go there instead of our DNS. |

### DNS

| Question | Answer |
| --- | --- |
| What is the difference between DNS resolution and the connection? | DNS only returns an IP (UDP 53, ~20 ms). The TCP/TLS connection to that IP is a separate, later step. |
| Show that your DNS is really used. | `dig app.dimaginaxal.test` shows `SERVER: 10.7.12.240#53` and answer 10.7.29.80. `dig @8.8.8.8` gives NXDOMAIN. |
| What does the `aa` flag mean? | Authoritative answer: dnsmasq answered from its own records, not from a cache or by forwarding. |
| What if `listen-address` were only 127.0.0.1? | Only Mac 1 itself could use the DNS. Other Macs would time out. |
| What happens when the primary DNS goes down? | The client asks the next server in its list (Mac 3). Same answer, so the user doesn't notice. Evidence: `SERVER: 10.7.27.218`. |
| What is TTL, and what was yours? | How long an answer may be cached. 0 in Phase 1, 30 s in Phase 2. |
| Why did `dig` see the new record before curl did? | dig asks the server directly. curl uses the OS cache, which keeps the old answer until the TTL expires. |
| How do you make a client see a change immediately? | Flush the cache: `dscacheutil -flushcache` and `killall -HUP mDNSResponder`. |
| How do real companies use TTL in a migration? | Lower it (say to 60 s) a day before, switch the record, then raise it again. |
| What's the risk of two DNS servers? | They can drift. A record changed on only one means clients get different answers. |
| DNS failure vs application failure? | DNS failure: `Could not resolve host`. App failure: dig works, TLS works, but the response is 502. |

### TCP / UDP / ports

| Question | Answer |
| --- | --- |
| Why is DNS on UDP and HTTPS on TCP? | DNS is one small question and answer, so a handshake would only add delay. HTTPS needs a reliable, ordered stream. |
| Explain the 3-way handshake with numbers. | SYN seq=0 → SYN-ACK seq=0 ack=1 → ACK ack=1. Each ACK = the other side's seq + 1. |
| What is an ephemeral port? Give a socket pair. | A random high client port, e.g. `10.7.11.150:54821 → 10.7.29.80:443`. |
| How does TCP stay reliable over lossy Wi-Fi? | Sequence numbers, ACKs, retransmission, duplicate ACKs, the window. We saw retransmissions in the capture. |
| What's flow control? | The receiver advertises a window: how much unacknowledged data it can take. |
| Refused vs timeout? | Refused = RST, nothing listening on the port. Timeout = no reply at all (firewall drop or host gone). |
| Wrong port (e.g. 9999): what happens and why? | The host is reachable but nothing listens there, so the RST gives "connection refused". IP and port are separate identifiers. |

### TLS

| Question | Answer |
| --- | --- |
| Walk through the TLS 1.3 handshake. | ClientHello (versions, ciphers, key share, SNI) → ServerHello (choice, key share) → encrypted Certificate, CertificateVerify, Finished → client Finished → Application Data. |
| Why can't Wireshark show the HTTP headers? | They're inside encrypted TLS records, so Wireshark only sees "Application Data". |
| Why is there no Certificate packet in your capture? | In TLS 1.3 the certificate is sent encrypted. |
| What's SNI and why does it matter? | The hostname in the ClientHello, in plaintext. It tells the server which certificate to use. |
| How does the client decide to trust your certificate? | It chains to our mkcert root CA in the System keychain, the SAN matches the name, the dates are valid, and the server proves it has the key. |
| Why did Mac 3 reject the certificate at first? | The certificate was fine. Mac 3 just didn't trust our CA yet. Importing `rootCA.pem` fixed it. |
| What would happen if `rootCA-key.pem` leaked? | Anyone could sign certificates for any name that our Macs would trust. |
| Where is TLS terminated? Is edge → backend secure? | At nginx. Edge → backend is plain HTTP on the LAN; Phase 1 Figure 3 shows the readable GET. In production you'd re-encrypt or use mTLS on untrusted networks. |
| Why must you not use `curl -k`? | It skips verification, so it proves nothing about trust. |
| Why did the same certificate work on the standby edge? | Certificates are bound to the hostname (SAN), not to an IP. |

### HTTP and caching

| Question | Answer |
| --- | --- |
| What does `Cache-Control: public, max-age=60` mean? | Any cache may reuse the response for 60 s without asking. |
| Fresh hit vs conditional request vs full request? | No request at all / 304 with headers only / 200 with the full body. |
| How does your 304 work? | The backend hashes the body into an ETag. If the client sends that value back in `If-None-Match`, it returns 304. |
| Why did you add `/api/info`? | Its body is the same on A and B, so the ETag matches whichever backend nginx picks. |
| HTTP/1.1 vs HTTP/2 vs HTTP/3? | 2: binary, multiplexed, header compression, negotiated by ALPN. 3: over QUIC/UDP, no TCP head-of-line blocking. Our curl shows `HTTP/2 200`. |
| 502 vs 504? | 502: the upstream refused or sent a bad response. 504: the upstream took too long. |
| What does `X-Forwarded-For` do? | Passes the real client IP to the backend. Without it the backend only sees nginx's IP. |

### Load balancing and failover

| Question | Answer |
| --- | --- |
| Why doesn't the client need the backend IPs? | It only talks to the edge. nginx picks the backend, so backends can change without touching clients. |
| How do you prove load balancing? | Repeated curl shows A, B, A, B, and the edge log alternates `upstream=…:3001` / `…:3002`. |
| What happened when you stopped Backend A? | nginx got refused, retried the same request on B, and the client got 200. Log: `upstream=…3001, …3002 upstream_status=502, 200`. Then only B for a while. |
| How does nginx know A is back? | After `fail_timeout` (10 s) it sends A a real request again. If that works, A is back in rotation. These are passive checks. |
| Both backends down? | nginx answers 502 itself. DNS and TLS still work, showing where the edge ends and the backends begin. |
| What's still a single point of failure? How do you fix it? | The edge on Mac 2. Fix with a floating VIP (VRRP), DNS failover, or a managed load balancer across availability zones. |
| How did the DNS cutover work? | Started a standby nginx on Mac 3, changed the A record to 10.7.27.218 on both DNS servers. Cached clients stayed on mac2 for up to 30 s, then moved to mac3. |
| Why keep the old edge running during the cutover? | Clients with the old cached answer still use it until their TTL expires. Shutting it down early would break them. |

### Firewall

| Question | Answer |
| --- | --- |
| What do your pf rules do? | Allow TCP to 3001 from 10.7.29.80 only. Drop everyone else on that port. |
| Why could Mac 1 still ping Mac 3? | ICMP isn't TCP 3001. We filtered only the port. |
| Why a timeout and not "refused"? | `block drop` silently drops the SYN. |
| What does `quick` mean? | The first matching rule wins and no further rules are checked. |
| How do you roll back? | `sudo pfctl -f /etc/pf.conf`, after keeping a copy of the original rules. |

### Troubleshooting (Extension F)

| Question | Answer |
| --- | --- |
| The site doesn't load. What do you check first? | DNS → IP → TCP → TLS → HTTP → backend, stopping at the first failure. |
| `curl: (6)`? | DNS. Check the client's DNS servers and whether dnsmasq is running. |
| `curl: (7)` on 443? | Nothing listening. nginx is down or on the wrong port. |
| `curl: (60)`? | Certificate not trusted, or the name doesn't match. |
| 502? | The edge is fine. Check the backends from Mac 2 and check the upstream config. |
| dig answers but with the wrong IP? | DNS data is wrong: "DNS is a directory, not a connection". Fix the record on **both** servers. |

### Questions about real problems you hit (examiners love these)

- "Your IPs changed between phases. Why, and what did you have to do?" (DHCP; updated every Phase 2 config.)
- "Your git push failed with `Could not resolve host` during setup. Why?" (Mac 2 was pointed at DNS servers that weren't running yet.)
- "Viraj's watcher printed only timestamps. How did you find the cause?" (`-s` hid the error. Without it: curl error 6 = DNS. The Mac had no DNS servers set.)
- "nginx said `Address already in use`. What did that mean?" (It was already running. `lsof` showed nginx on 443.)

---

## Part 4: The final demo (Section 8 of the spec)

Rehearse with a timer. Everyone should be able to drive **any** step.

| # | Step | Command / action | What to say |
| --- | --- | --- | --- |
| 1 | Topology + IP table | Phase 2 report, Section 2 | Each role and its cloud equivalent |
| 2 | All on the LAN | `for ip in 10.7.12.240 10.7.29.80 10.7.27.218 10.7.11.150; do ping -c 2 $ip \| tail -2; done` | Same /19, direct delivery |
| 3 | Resolve the name | `dig app.dimaginaxal.test` | SERVER line = our DNS, answer = edge IP, TTL 30, `aa` flag |
| 4 | HTTPS by name | browser padlock + `curl -v https://app.dimaginaxal.test/api/status` | TLSv1.3, SAN match, "verify ok", no `-k`, no IP in the URL |
| 5 | Load balancing | A/B loop | Round-robin, the client never sees the backend IPs |
| 6 | Wireshark | saved capture, filter `dns \|\| tcp.port == 443` | DNS query/answer → SYN/SYN-ACK/ACK → ClientHello with SNI → Application Data |
| 7 | Caching | `curl -sI …/api/info` then with `If-None-Match` → 304 | The three cases |
| 8 | Backend failure | stop Backend A, watcher + edge log | Retry line `502, 200`, only B, then recovery |
| 9 | Phase 2 DNS | stop Mac 1 dnsmasq → `SERVER: 10.7.27.218`; or the TTL watcher | Redundancy, TTL, migration |
| 10 | Injected fault | `./scripts/diagnose.sh` + manual checks | Say each layer out loud |
| 11 | Viva | — | Your own words, your own evidence |

**Before the demo:** check the IPs, start DNS → backends → nginx, point the clients at both DNS servers, quit VPNs and Tailscale, keep laptops plugged in, and have the screenshots and the `.pcapng` open.

---

## Part 5: Study plan

| Day | Focus | Done when you can… |
| --- | --- | --- |
| 1 | Part 1 story + layer map | Tell the request story in 2 minutes without notes, and draw the topology |
| 2 | DNS + IP/ARP (2.1, 2.2) | Explain every line of `dnsmasq-primary.conf` and every line of `dig` output |
| 3 | TCP + TLS (2.3, 2.4) | Point at SYN / SYN-ACK / ACK and the ClientHello in Wireshark, and explain certificate trust |
| 4 | HTTP, caching, nginx (2.5, 2.6) | Explain every line of `config/phase2/nginx.conf`, and the 304 |
| 5 | Phase 2 + firewall (2.7) | Explain each extension using its screenshot and timestamps |
| 6 | Troubleshooting + rehearsal (2.8, Part 4) | Diagnose 3 faults a teammate injected, out loud |

**Sachin (edge):** expect deep questions on nginx and TLS. Know every line of `nginx.conf`, where the certificate and key live and why the key is `chmod 600`, what `proxy_next_upstream` does, and how you'd remove the single point of failure. Also be ready for DNS questions, since examiners like to ask people about parts they didn't build.

**Practise by doing:** in Wireshark, filter `dns || tcp.port == 443`, run `curl https://app.dimaginaxal.test/api/status` once, and name every packet. If you can do that, you understand the project.
