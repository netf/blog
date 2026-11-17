#!/usr/bin/env bash
# Usage: 10-cluster.sh iptables|nftables|cilium
# Builds one lab cluster: dataplane, MetalLB, Envoy Gateway, Traefik, the two
# tenants, and two out-of-cluster hosts on the Kind network:
#   payments-ext  172.18.0.200 / fc00:f853:ccd:e793::200  "payments.internal" (real cert)
#   orders-db     172.18.0.210                              a legitimate external database
set -euo pipefail
DP=${1:-}
case "$DP" in iptables|nftables|cilium) ;; *) echo "usage: $0 iptables|nftables|cilium" >&2; exit 2;; esac
cd "$(dirname "$0")/.."
export PATH=~/bin:$PATH
CL=svcg-$DP
METALLB_CHART=0.16.2
EG_VERSION=v1.10.0
TRAEFIK_CHART=42.4.0
TRAEFIK_IMAGE=v3.7.19

kind get clusters | grep -qx "$CL" || kind create cluster --name "$CL" --config "kind-$DP.yaml"
kubectl config use-context "kind-$CL"
# Refuse to reuse a cluster whose dataplane doesn't match its name (stale run).
mode=$(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | awk '/^mode:/{print $2}' | tr -d '"' || true)
want=$DP; [ "$DP" = cilium ] && want=""
[ "$mode" = "$want" ] || { echo "$CL runs kube-proxy mode '${mode:-none}', expected '${want:-none}'; delete it with: kind delete cluster --name $CL" >&2; exit 1; }
./scripts/02b-host-iptables-fix.sh
if [ "$DP" = cilium ]; then
  helm upgrade --install cilium cilium/cilium --version 1.20.4 -n kube-system -f scripts/cilium-values.yaml
  cilium status --wait --wait-duration 5m >/dev/null
fi
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kind load docker-image svcguard-lab:1 --name "$CL"

./scripts/03-certs.sh >/dev/null
C=$PWD/.work/certs
for addr in 172.18.0.200 172.18.0.210 fc00:f853:ccd:e793::200; do
  python3 -c "import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if any(a in ipaddress.ip_network(n) for n in sys.argv[2:] if ipaddress.ip_network(n).version==a.version) else 1)" \
    "$addr" $(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}') ||
    { echo "$addr is outside the kind network's subnets; the lab's fixed external hosts assume 172.18.0.0/16 and fc00:f853:ccd:e793::/64" >&2; exit 1; }
done
docker rm -f payments-ext orders-db >/dev/null 2>&1 || true
docker run -d --name payments-ext --network kind --ip 172.18.0.200 --ip6 fc00:f853:ccd:e793::200 \
  -v "$C":/certs:ro svcguard-lab:1 serve --name payments-ext-real --http-port 80 --tls-port 443 \
  --cert /certs/payments.crt --key /certs/payments.key >/dev/null
docker run -d --name orders-db --network kind --ip 172.18.0.210 svcguard-lab:1 serve --name orders-db-external --http-port 5432 >/dev/null

# L2 mode only; the BGP (frr-k8s) backend is not needed on one Docker bridge.
helm upgrade --install metallb metallb/metallb --version $METALLB_CHART -n metallb-system --create-namespace \
  --set frrk8s.enabled=false --wait --timeout 5m
for i in $(seq 1 30); do kubectl apply -f manifests/metallb-pool.yaml && break; sleep 5; done
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version $EG_VERSION -n envoy-gateway-system --create-namespace --wait --timeout 5m
helm upgrade --install traefik traefik/traefik --version $TRAEFIK_CHART -n traefik --create-namespace \
  --set image.tag=$TRAEFIK_IMAGE --wait --timeout 5m
kubectl apply -f manifests/gateway.yaml

kubectl apply -f manifests/tenants.yaml
kubectl -n tenant-a create secret generic payments-tls --from-file="$C/payments.crt" --from-file="$C/payments.key" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tenant-a create secret generic lab-ca --from-file="$C/ca.crt" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tenant-b create secret generic attacker-tls --from-file="$C/attacker.crt" --from-file="$C/attacker.key" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tenant-a rollout status deploy/payments --timeout=180s
kubectl -n tenant-a rollout status deploy/checkout --timeout=180s
kubectl -n tenant-b rollout status deploy/impostor --timeout=180s
kubectl -n infra wait --for=condition=Programmed gateway/shared --timeout=180s
kubectl -n tenant-a wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' svc/payments-lb --timeout=120s >/dev/null

mkdir -p results/$DP
{
  echo "cluster $CL $(date -u +%FT%TZ)"
  kubectl version -o json | jq -r '"server " + .serverVersion.gitVersion'
  kubectl get nodes -o wide --no-headers | awk '{print "node", $1, $5, $6, $(NF)}'
  helm list -A -o json | jq -r '.[] | "helm \(.name) \(.chart) app=\(.app_version)"'
  kubectl get pods -A -o json | jq -r '.items[].spec.containers[].image' | sort -u | sed 's/^/image /'
  kubectl get pods -A -o json | jq -r '.items[].status.containerStatuses[]?.imageID' | sort -u | sed 's/^/imageID /'
} > results/$DP/versions.txt
echo "payments-lb IP: $(kubectl -n tenant-a get svc payments-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
