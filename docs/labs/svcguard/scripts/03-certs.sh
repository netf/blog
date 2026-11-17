#!/usr/bin/env bash
# Lab-only PKI in .work/certs (gitignored). The real payments service gets a cert
# from the lab CA; the attacker only has a self-signed cert for the same name.
set -euo pipefail
D=.work/certs; mkdir -p $D; cd $D
[ -f ca.crt ] && exit 0
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=svcguard-lab-ca -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -keyout ca.key -out ca.crt 2>/dev/null
SAN="DNS:payments.internal,DNS:payments.tenant-a.svc,DNS:payments.tenant-a.svc.cluster.local"
openssl req -newkey rsa:2048 -nodes -subj /CN=payments.internal -keyout payments.key -out payments.csr 2>/dev/null
openssl x509 -req -in payments.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile <(printf "subjectAltName=$SAN\nauthorityKeyIdentifier=keyid\nsubjectKeyIdentifier=hash\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n") -out payments.crt 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=payments.internal -addext "subjectAltName=$SAN" -keyout attacker.key -out attacker.crt 2>/dev/null
ls
