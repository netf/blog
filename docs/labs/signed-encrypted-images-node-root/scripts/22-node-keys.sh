#!/usr/bin/env bash
# Node-side decryption (containerd "node" key model). Both workers get the
# imgcrypt stream processor; only supply-worker gets the private key.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
OUT="$LAB/results/node-keys"; mkdir -p "$OUT"
KD=/etc/containerd/ocicrypt/keys
for n in supply-worker supply-worker2; do
  docker cp "$HOME/bin/ctd-decoder" "$n:/usr/local/bin/ctd-decoder"
  docker exec "$n" mkdir -p "$KD"
  docker exec "$n" grep -q ocicrypt.decoder /etc/containerd/config.toml || \
  docker exec -i "$n" tee -a /etc/containerd/config.toml >/dev/null <<TOML

[plugins."io.containerd.cri.v1.images".image_decryption]
  key_model = "node"

[stream_processors]
  [stream_processors."io.containerd.ocicrypt.decoder.v1.tar.gzip"]
    accepts = ["application/vnd.oci.image.layer.v1.tar+gzip+encrypted"]
    returns = "application/vnd.oci.image.layer.v1.tar+gzip"
    path = "/usr/local/bin/ctd-decoder"
    args = ["--decryption-keys-path", "$KD"]
  [stream_processors."io.containerd.ocicrypt.decoder.v1.tar"]
    accepts = ["application/vnd.oci.image.layer.v1.tar+encrypted"]
    returns = "application/vnd.oci.image.layer.v1.tar"
    path = "/usr/local/bin/ctd-decoder"
    args = ["--decryption-keys-path", "$KD"]
TOML
done
docker cp "$LAB/keys/enc-priv.pem" "supply-worker:$KD/enc-priv.pem"
docker exec supply-worker chmod 600 "$KD/enc-priv.pem"
for n in supply-worker supply-worker2; do
  docker exec "$n" systemctl restart containerd
done
kubectl wait --for=condition=Ready node --all --timeout=120s >/dev/null
for n in supply-worker supply-worker2; do
  echo "== $n"
  docker exec "$n" containerd config dump 2>/dev/null | grep -A1 -E 'image_decryption|ocicrypt.decoder.v1.tar.gzip' | head -4
  docker exec "$n" ls -l "$KD"
done | tee "$OUT/config.txt"
