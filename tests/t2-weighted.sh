#!/bin/bash
# T2 — weighted regional routing (Env A).
# Applies the weighted hub policy (eu:8, us:2), sends N requests, and checks the
# observed split against the configured weights with a chi-square criterion
# (p=0.05) fixed BEFORE the run.
# Usage: ./t2-weighted.sh <n-requests> <output.jsonl>
set -euo pipefail

N="${1:-200}"
OUT="${2:?output.jsonl}"
HUB_IP="34.75.150.223"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"
[ -s "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"

echo "==> applying weighted (eu 8 / us 2) hub policy"
helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version v1.0.0 --kube-context llmd-poc-us --namespace llmd-serving \
  -f "${REPO_ROOT}/k8s/hub/router-values.t2-weighted.yaml" >/dev/null
kubectl --context llmd-poc-us -n llmd-serving rollout status deploy/llmd-hub-epp --timeout=180s

echo "==> sending ${N} requests via hub"
: > "${OUT}"
for i in $(seq 1 "${N}"); do
  resp=$(curl -sS -m 60 -i -X POST "http://${HUB_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"llmd-poc-sim","messages":[{"role":"user","content":"t2 probe '"$i"'"}],"max_tokens":4}' 2>/dev/null || true)
  status=$(printf '%s' "$resp" | head -1 | awk '{print $2}')
  token=$(printf '%s' "$resp" | grep -i '^x-session-token:' | awk '{print $2}' | tr -d '\r' || true)
  pod=$(printf '%s' "$resp" | grep -i '^x-inference-pod:' | awk '{print $2}' | tr -d '\r' || true)
  cluster=$(printf '%s' "$token" | base64 -d 2>/dev/null | cut -d/ -f2 || true)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","policy":"weighted-eu8-us2","seq":%d,"http":%s,"hub_region":"%s","pod":"%s"}\n' \
    "$ts" "$i" "${status:-000}" "${cluster:-none}" "${pod:-none}" >> "${OUT}"
done

echo "==> T2 summary (expected eu 80% / us 20%)"
python3 - "$OUT" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ok = [r for r in rows if r.get("http") in (200, "200")]
eu = sum(1 for r in ok if r.get("hub_region") == "eu")
us = sum(1 for r in ok if r.get("hub_region") == "us")
n = len(ok)
print(f"total={len(rows)} http200={n} eu={eu} us={us}")
if n:
    e_eu, e_us = 0.8 * n, 0.2 * n
    chi2 = (eu - e_eu) ** 2 / e_eu + (us - e_us) ** 2 / e_us
    verdict = "PASS" if chi2 < 3.841 else "FAIL"
    print(f"chi2={chi2:.2f} (crit 3.841, p=0.05) -> {verdict}")
    print("pod distribution:")
    from collections import Counter
    for pod, c in Counter(r["pod"] for r in ok).most_common():
        print(f"  {c:4d} {pod}")
EOF
