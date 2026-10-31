#!/usr/bin/env bash
# Minimal SIP-over-WebSocket client, standing in for a browser (JsSIP, SIP.js):
# registers <user> over wss on Asterisk, then answers OPTIONS (qualify) with
# 200 and INVITEs with 486, logging every message it receives.
#
#   webrtc-client.sh <user> <password> <log>    # runs until killed
#
# The log gets "REGISTER <status>" for each REGISTER answer, then the raw messages.
set -uo pipefail

user="$1" pass="$2" log="$3"
server=172.31.251.11
md5() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
rnd() { head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
host="$(rnd).invalid"
: >"$log"

# -0: one SIP message per WebSocket message, \0-separated on stdin/stdout.
coproc WS { websocat -0 -t -k --protocol sip "wss://$server:8089/ws" 2>>"$log"; }
# send <line>...: one SIP message without body, lines joined with CRLF.
send() { { printf '%s\r\n' "$@" "Content-Length: 0" ""; printf '\0'; } >&"${WS[1]}"; }
recv() { IFS= read -r -d '' -t "${1:-10}" msg <&"${WS[0]}"; }
header() { grep -i "^$1:" <<<"$msg" | head -1 | sed 's/^[^:]*: *//' | tr -d '\r'; }
status() { head -1 <<<"$msg" | cut -d' ' -f2; }

callid="$(rnd)" tag="$(rnd)" cseq=1
register() {
    send "REGISTER sip:$server SIP/2.0" \
         "Via: SIP/2.0/WSS $host;branch=z9hG4bK$(rnd)" \
         "Max-Forwards: 70" \
         "From: <sip:$user@$server>;tag=$tag" \
         "To: <sip:$user@$server>" \
         "Call-ID: $callid" \
         "CSeq: $cseq REGISTER" \
         ${1:+"Authorization: $1"} \
         "Contact: <sip:$user@$host;transport=ws>;expires=300" \
         "Expires: 300" \
         "User-Agent: provision-test webrtc-client"
    cseq=$((cseq + 1))
}

register
recv || { echo "REGISTER no answer" >>"$log"; exit 1; }
echo "REGISTER $(status)" >>"$log"
if [ "$(status)" = 401 ]; then
    challenge="$(header WWW-Authenticate)"
    nonce="$(sed -n 's/.*nonce="\([^"]*\)".*/\1/p' <<<"$challenge")"
    realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")"
    opaque="$(sed -n 's/.*opaque="\([^"]*\)".*/\1/p' <<<"$challenge")"
    cnonce="$(rnd)" uri="sip:$server"
    response="$(md5 "$(md5 "$user:$realm:$pass"):$nonce:00000001:$cnonce:auth:$(md5 "REGISTER:$uri")")"
    register "Digest username=\"$user\", realm=\"$realm\", nonce=\"$nonce\", uri=\"$uri\", response=\"$response\", algorithm=MD5, qop=auth, nc=00000001, cnonce=\"$cnonce\"${opaque:+, opaque=\"$opaque\"}"
    recv || { echo "REGISTER no answer" >>"$log"; exit 1; }
    echo "REGISTER $(status)" >>"$log"
fi

# Requests from Asterisk: answer copying Via, From, To, Call-ID and CSeq.
while recv 3600; do
    printf '%s\n' "$msg" >>"$log"
    method="${msg%% *}"
    case "$method" in
        OPTIONS) code="200 OK" ;;
        INVITE)  code="486 Busy Here" ;;
        *)       continue ;;
    esac
    mapfile -t vias < <(printf '%s\n' "$msg" | grep -i '^Via:' | tr -d '\r')
    send "SIP/2.0 $code" "${vias[@]}" \
         "From: $(header From)" \
         "To: $(header To);tag=$tag" \
         "Call-ID: $(header Call-ID)" \
         "CSeq: $(header CSeq)"
done
