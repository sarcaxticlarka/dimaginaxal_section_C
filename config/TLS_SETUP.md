# TLS Setup

HTTPS for `app.dimaginaxal.test` ends at nginx on **Mac 2 (10.7.1.138)**. The client to nginx leg is encrypted with TLS 1.3. The nginx to backend leg stays plain HTTP inside the LAN.

We used **mkcert v1.4.4**. It creates a small local certificate authority (CA) and signs certificates with it. Any Mac that trusts the CA then accepts our certificate without warnings, so we never need `curl -k`.

---

## 1. Create the CA and certificate (Mac 2 only)

```bash
brew install mkcert
mkcert -install
```

`mkcert -install` creates the CA and adds it to Mac 2's own keychain. The CA files are stored in:

```
~/Library/Application Support/mkcert/
├── rootCA.pem        public, safe to share
└── rootCA-key.pem    PRIVATE, never share or commit
```

Create the server certificate:

```bash
mkdir -p ~/dimaginaxal/certs && cd ~/dimaginaxal/certs
mkcert app.dimaginaxal.test
```

This writes two files:

| File | What it is |
| --- | --- |
| `app.dimaginaxal.test.pem` | Certificate (public) |
| `app.dimaginaxal.test-key.pem` | Private key (stays on Mac 2) |

The certificate is valid until **4 January 2029**.

---

## 2. Give the certificate to nginx

```bash
sudo mkdir -p /opt/homebrew/etc/nginx/certs
sudo cp app.dimaginaxal.test.pem app.dimaginaxal.test-key.pem /opt/homebrew/etc/nginx/certs/
sudo chmod 600 /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test-key.pem
```

The matching part of `nginx.conf`:

```nginx
server {
    listen 443 ssl;
    server_name app.dimaginaxal.test;

    ssl_certificate     /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test.pem;
    ssl_certificate_key /opt/homebrew/etc/nginx/certs/app.dimaginaxal.test-key.pem;

    location / {
        proxy_pass http://backend_pool;
    }
}
```

Port 80 only redirects to HTTPS:

```nginx
server {
    listen 80;
    server_name app.dimaginaxal.test;
    return 301 https://$host$request_uri;
}
```

Test the config and reload:

```bash
sudo nginx -t
sudo nginx -s reload
```

---

## 3. Make the other Macs trust the CA

At first Mac 3 rejected the certificate. The certificate itself was fine, but Mac 3 did not know our CA. To fix it, copy **only `rootCA.pem`** from Mac 2 to each client (AirDrop works) and run:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/rootCA.pem
```

Do this on every Mac that acts as a client. So far this has been done on Mac 3; Mac 2 trusts the CA through `mkcert -install`.

Restart the browser afterwards so it picks up the new trust.

---

## 4. Verify

```bash
curl -v https://app.dimaginaxal.test/api/status
```

Things to look for in the output:

- `SSL connection using TLSv1.3`
- `subject: ... app.dimaginaxal.test`
- `SSL certificate verify ok.`
- The response `{"backend":"A","status":"ok"}`

Run it **without** `-k`. If it works, certificate checking passed.

In a browser, `https://app.dimaginaxal.test` should show the padlock with no warning.

---

## 5. Seeing the handshake in Wireshark

Capture on Mac 2's `en0` with the filter:

```
tls && ip.addr == 10.7.1.138
```

| Packet | Direction | What it shows |
| --- | --- | --- |
| Client Hello | client → 10.7.1.138:443 | TLS versions offered, SNI = `app.dimaginaxal.test` |
| Server Hello, Change Cipher Spec | 10.7.1.138 → client | nginx picks TLS 1.3 and a cipher |
| Application Data | both ways | Encrypted handshake (certificate, finished) and the HTTP request/response |

In TLS 1.3 the certificate travels **encrypted**, so Wireshark does not list a separate "Certificate" packet. It is inside the first Application Data records from the server. Only TLS 1.2 shows it in plain view.

---

## What must stay private

| File | Where it lives | Commit to Git? |
| --- | --- | --- |
| `rootCA.pem` | Mac 2, copied to clients | Yes, it is public |
| `app.dimaginaxal.test.pem` | Mac 2 | Yes, it is public |
| `rootCA-key.pem` | Mac 2 only | **No.** Anyone with it can sign certificates our Macs will trust |
| `app.dimaginaxal.test-key.pem` | Mac 2 only | **No** |

Both private keys are excluded by `.gitignore` (`*-key.pem`).