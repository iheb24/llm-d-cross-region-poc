#!/bin/bash
# repoint-ips.sh — refresh every IP-bearing tracked file after a rebuild.
# Reads terraform outputs (gateway IPs) + the US Cloud NAT's allocated egress
# IPs + the operator's current public IP, then rewrites:
#   k8s/region-eu/envoyproxy.yaml  (loadBalancerIP + loadBalancerSourceRanges)
#   k8s/region-us/envoyproxy.yaml  (loadBalancerIP + loadBalancerSourceRanges)
#   k8s/hub/gateway.yaml           (loadBalancerIP + loadBalancerSourceRanges)
#   k8s/hub/clusters.yaml          (regional gateway addresses)
#   tests/*.sh tests/*.py          (HUB constants)
# loadBalancerSourceRanges = [operator IP, all PoC NAT egress IPs] so the
# gateways answer only the operator and hub traffic (hub -> spoke via NAT).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
PROJECT_ID=$(awk -F'"' '/project_id/ {print $2; exit}' infra/environments/us/terraform.tfvars)

EU_GW=$(terraform -chdir=infra/environments/eu output -raw gateway_ip)
US_GW=$(terraform -chdir=infra/environments/us output -raw gateway_ip)
HUB_GW=$(terraform -chdir=infra/environments/us output -raw hub_gateway_ip)

NAT_IPS=$(gcloud compute routers get-nat-ip-info llmd-poc-vpc-router-us-east1 \
  --region=us-east1 --project="$PROJECT_ID" \
  | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u)
OPERATOR_IP=$(curl -sS -4 -m 10 ifconfig.me)

[ -n "$OPERATOR_IP" ] || { echo "cannot determine operator IPv4"; exit 1; }
[ -n "$NAT_IPS" ] || { echo "no NAT IPs discovered for us-east1 router"; exit 1; }

# operator + hub NAT egress + both PoC pod ranges (intra-VPC hub -> same-region
# gateway does NOT traverse the NAT, it keeps the pod source IP)
RANGES="["
for ip in $OPERATOR_IP $NAT_IPS; do RANGES+="\"$ip/32\", "; done
RANGES+="\"10.12.0.0/14\", \"10.24.0.0/14\"]"
echo "eu=$EU_GW us=$US_GW hub=$HUB_GW operator=$OPERATOR_IP nat=[$NAT_IPS]"

python3 - "$EU_GW" "$US_GW" "$HUB_GW" "$RANGES" <<'EOF'
import re, sys, pathlib, glob
eu, us, hub, ranges = sys.argv[1:5]

def set_lb(path, ip):
    p = pathlib.Path(path)
    s = p.read_text()
    s = re.sub(r'loadBalancerIP: \S+', f'loadBalancerIP: {ip}', s, count=1)
    s = re.sub(r'loadBalancerSourceRanges: \[[^\]]*\]', f'loadBalancerSourceRanges: {ranges}', s, count=1)
    p.write_text(s)

set_lb('k8s/region-eu/envoyproxy.yaml', eu)
set_lb('k8s/region-us/envoyproxy.yaml', us)
set_lb('k8s/hub/gateway.yaml', hub)

c = pathlib.Path('k8s/hub/clusters.yaml')
lines = c.read_text().splitlines()
region = None
for i, l in enumerate(lines):
    m = re.match(r'\s*- name: (eu|us)\s*$', l)
    if m:
        region = m.group(1)
    if re.match(r'\s*address: ', l) and region:
        lines[i] = re.sub(r'address: \S+', f'address: {eu if region == "eu" else us}', l)
c.write_text('\n'.join(lines) + '\n')

for f in glob.glob('tests/*.sh') + glob.glob('tests/*.py'):
    p = pathlib.Path(f)
    t = p.read_text()
    t2 = re.sub(r'(?<=HUB=")[0-9.]+|(?<=HUB_IP=")[0-9.]+|(?<=HUB = ")[0-9.]+', hub, t)
    if t2 != t:
        p.write_text(t2)
print('repointed: manifests + clusters.yaml + tests')
EOF
