#!/bin/sh
set -eu

key=/etc/kimi-gateway/device-issuer.key.pem
cert=/etc/kimi-gateway/device-issuer.crt.pem

if [ -s "$key" ] && [ -s "$cert" ]; then
  echo "device issuer already exists"
  exit 0
fi

umask 077
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key" >/dev/null 2>&1
openssl req -new -x509 -key "$key" -sha256 -days 3650 \
  -subj '/CN=Agent Remote Device Issuer' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -out "$cert"
chmod 600 "$key"
chmod 644 "$cert"
echo "created device issuer"
