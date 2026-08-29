#!/usr/bin/env bash
# The certificates the interop stack talks over.
#
# Mastodon in production publishes https and refuses to be anything else, so
# two servers on plain HTTP cannot fetch each other however correct both are.
# Rather than pretend, the stack terminates TLS in front of every server and
# every container trusts the one authority that signed them.
#
# Regenerated when missing and reused when not: they are worthless outside this
# Docker network, and making them takes a second that every run would pay.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/generated"

if [ -f "$out/server.crt" ] && [ -f "$out/ca.crt" ]; then
  exit 0
fi

mkdir -p "$out"

# An authority of our own, and one certificate covering every name in the
# stack. One certificate rather than three because a single proxy answers for
# all of them and SNI would only add a way to get it wrong.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$out/ca.key" -out "$out/ca.crt" \
  -subj "/CN=abuuba interop authority" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

openssl req -newkey rsa:2048 -nodes \
  -keyout "$out/server.key" -out "$out/server.csr" \
  -subj "/CN=abuuba.interop" 2>/dev/null

openssl x509 -req -in "$out/server.csr" -sha256 -days 3650 \
  -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial \
  -out "$out/server.crt" \
  -extfile <(printf 'subjectAltName=DNS:abuuba.interop,DNS:mastodon.interop,DNS:gotosocial.interop\nbasicConstraints=CA:FALSE\n') \
  2>/dev/null

# What the containers mount over their trust store. Only this authority is in
# it: nothing in the stack talks to anything outside it, and a bundle with one
# certificate in it is one nobody has to wonder about.
cp "$out/ca.crt" "$out/bundle.crt"

rm -f "$out/server.csr"
