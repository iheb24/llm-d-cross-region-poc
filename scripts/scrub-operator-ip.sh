#!/bin/bash
# scrub-operator-ip.sh — replace the operator's public IP with OPERATOR_IP in
# tracked files before committing. repoint-ips.sh writes the live value for the
# running stack; this restores the committable placeholder.
# Usage: scripts/scrub-operator-ip.sh [ip-to-scrub]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
IP="${1:-$(curl -sS -4 -m 10 ifconfig.me)}"
[ -n "$IP" ] || { echo "no IP to scrub"; exit 1; }
grep -rl -- "$IP" k8s/ docs/ tests/ infra/ scripts/ 2>/dev/null | grep -v scripts/scrub-operator-ip.sh | while read -r f; do
  sed -i '' "s|$IP|OPERATOR_IP|g" "$f"
  echo "scrubbed: $f"
done
echo "done — review with git diff before committing"
