#!/bin/bash
# Layer-by-layer diagnosis (Phase 2, Extension F):
#   1 DNS  ->  2 IP  ->  3 TCP  ->  4 TLS  ->  5 HTTP  ->  6 backends
# Stops at the first broken layer and says which layer it is.
#
# Usage:  ./scripts/diagnose.sh [host] [port]
#         ./scripts/diagnose.sh app.dimaginaxal.test 443

HOST="${1:-app.dimaginaxal.test}"
PORT="${2:-443}"
URL="https://$HOST:$PORT/api/status"

ok()   { printf "   \033[32mOK  \033[0m %s\n" "$1"; }
bad()  { printf "   \033[31mFAIL\033[0m %s\n" "$1"; }
info() { printf "        %s\n" "$1"; }

echo "== 1. DNS: can we turn $HOST into an IP?"
for ns in $(scutil --dns | awk '/nameserver\[[0-9]+\]/{print $3}' | sort -u); do info "resolver configured: $ns"; done
IP=$(dig +short +time=2 +tries=1 "$HOST" A | grep -E '^[0-9.]+$' | tail -1)
if [ -z "$IP" ]; then
    bad "no A record for $HOST  ->  DNS LAYER"
    dig +time=2 +tries=1 "$HOST" | grep -E 'status:|SERVER:|timed out|refused' | sed 's/^/        /'
    info "check: is dnsmasq running on Mac 1 / Mac 3? is this Mac using them? (networksetup -getdnsservers Wi-Fi)"
    exit 1
fi
ok "$HOST -> $IP  ($(dig +time=2 +tries=1 "$HOST" | awk '/SERVER:/{print "answered by " $3}'))"
info "expected 10.7.29.80 (Mac 2) unless a cutover is in progress"

echo "== 2. IP: is $IP reachable?"
if ping -c 2 -t 3 "$IP" >/dev/null 2>&1; then ok "ping $IP"
else bad "ping $IP failed (host down, wrong IP in DNS, or not on this LAN)"; fi

echo "== 3. TCP: can we open $IP:$PORT?"
if nc -z -G 3 "$IP" "$PORT" >/dev/null 2>&1; then ok "TCP handshake to $IP:$PORT"
else
    bad "cannot connect to $IP:$PORT  ->  TCP / TRANSPORT LAYER"
    info "refused = nothing listening (nginx stopped, wrong port); timeout = firewall drop or host gone"
    exit 1
fi

echo "== 4. TLS: does the certificate check out?"
echo | openssl s_client -connect "$IP:$PORT" -servername "$HOST" 2>/dev/null \
    | openssl x509 -noout -subject -issuer -enddate 2>/dev/null | sed 's/^/        /'
CODE=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 "$URL" 2>/tmp/diagnose_curl_err.$$)
RC=$?
ERR=$(cat /tmp/diagnose_curl_err.$$); rm -f /tmp/diagnose_curl_err.$$
case $RC in
    0)  ok "TLS handshake + certificate verified (no -k)";;
    60|51|58|77) bad "certificate rejected  ->  TLS LAYER"; info "$ERR"
        info "check: CA trusted on this Mac? cert SAN = $HOST? right cert in nginx?"; exit 1;;
    35) bad "TLS handshake failed  ->  TLS LAYER"; info "$ERR"; exit 1;;
    6)  bad "curl could not resolve $HOST (system resolver differs from dig?)  ->  DNS"; info "$ERR"; exit 1;;
    7)  bad "connection refused  ->  TCP"; info "$ERR"; exit 1;;
    28) bad "timed out  ->  TCP or backend hang"; info "$ERR"; exit 1;;
    *)  bad "curl error $RC"; info "$ERR"; exit 1;;
esac

echo "== 5. HTTP: what does the edge answer?"
HDRS=$(curl -s -o /dev/null -D - --max-time 8 "$URL")
echo "$HDRS" | grep -iE '^(HTTP|x-backend|x-edge|cache-control|etag)' | tr -d '\r' | sed 's/^/        /'
case $CODE in
    200) ok "HTTP $CODE from $(echo "$HDRS" | awk -F': ' 'tolower($1)=="x-backend"{print "backend " $2}' | tr -d '\r')";;
    502|504) bad "HTTP $CODE  ->  edge is fine, BACKENDS unreachable (APPLICATION / UPSTREAM)";;
    404) bad "HTTP 404  ->  wrong path, or request hit the wrong server block";;
    *)   bad "HTTP $CODE";;
esac

echo "== 6. Backends direct (only meaningful when run ON Mac 2 – pf blocks everyone else)"
for b in 10.7.27.218:3001 10.7.11.150:3002; do
    R=$(curl -s --connect-timeout 2 --max-time 4 "http://$b/api/status")
    if [ -n "$R" ]; then ok "$b  $R"; else bad "$b no answer (process stopped / bound to 127.0.0.1 / firewall)"; fi
done
