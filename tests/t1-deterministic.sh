#!/bin/bash
# T1 — deterministic regional selection (Env A).
# Applies a forced-region hub policy via helm, then verifies that every
# successful request is served in the forced region. Evidence: JSONL per request
# with hub decision (decoded x-session-token = cluster) + serving pod.
# Usage: ./t1-deterministic.sh <eu|us> <n-requests> <output.jsonl>
set -euo pipefail

REGION="${1:?eu|us}"
N="${2:-20}"
OUT="${3:?output.jsonl}"
HUB_IP="34.75.150.223"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"
[ -s "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"

echo "==> applying force-${REGION} hub policy"
helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
  --version v1.0.0 --kube-context llmd-poc-us --namespace llmd-serving \
  -f "${REPO_ROOT}/k8s/hub/router-values.force-${REGION}.yaml" >/dev/null
kubectl --context llmd-poc-us -n llmd-serving rollout status deploy/llmd-hub-epp --timeout=180s

echo "==> sending ${N} requests via hub"
: > "${OUT}"
for i in $(seq 1 "${N}"); do
  resp=$(curl -sS -m 60 -i -X POST "http://${HUB_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"llmd-poc-sim","messages":[{"role":"user","content":"t1 probe '"$i"'"}],"max_tokens":4}' 2>/dev/null || true)
  status=$(printf '%s' "$resp" | head -1 | awk '{print $2}')
  token=$(printf '%s' "$resp" | grep -i '^x-session-token:' | awk '{print $2}' | tr -d '\r' || true)
  pod=$(printf '%s' "$resp" | grep -i '^x-inference-pod:' | awk '{print $2}' | tr -d '\r' || true)
  cluster=$(printf '%s' "$token" | base64 -d 2>/dev/null | cut -d/ -f2 || true)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","policy":"force-%s","seq":%d,"http":%s,"hub_region":"%s","pod":"%s"}\n' \
    "$ts" "$REGION" "$i" "${status:-000}" "${cluster:-none}" "${pod:-none}" >> "${OUT}"
done

echo "==> summary for force-${REGION}"
total=$(wc -l < "${OUT}" | tr -d ' ')
ok=$(grep -c '"http":200' "${OUT}" || true)
inregion=$(grep -c "\"hub_region\":\"${REGION}\"" "${OUT}" || true)
echo "total=${total} http200=${ok} in_forced_region=${inregion}"
echo "pod distribution:"
grep '"http":200' "${OUT}" | sed 's/.*"pod":"\([^"]*\)".*/\1/' | sort | uniq -c
