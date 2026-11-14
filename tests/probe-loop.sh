#!/bin/bash
# T4 probe loop: sends a hub request every INTERVAL seconds and appends a JSONL
# record. Run in background during a failure-injection window; stop with kill.
# Usage: ./probe-loop.sh <output.jsonl> [interval_s] [case-label]
set -uo pipefail

OUT="${1:?output.jsonl}"
INTERVAL="${2:-2}"
CASE="${3:-t4}"
HUB_IP="34.138.131.34"
MODEL="${MODEL:-llmd-poc-sim}"   # real model: Qwen/Qwen2.5-Coder-14B-Instruct-AWQ

echo "probe-loop: case=${CASE} interval=${INTERVAL}s -> ${OUT} (pid $$)"
: > "${OUT}"
seq=0
while true; do
  seq=$((seq + 1))
  start=$(python3 -c 'import time; print(time.time())')
  resp=$(curl -sS -m 15 -i -X POST "http://${HUB_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"t4 probe"}],"max_tokens":4}' 2>/dev/null || true)
  status=$(printf '%s' "$resp" | head -1 | awk '{print $2}')
  token=$(printf '%s' "$resp" | grep -i '^x-session-token:' | awk '{print $2}' | tr -d '\r' || true)
  pod=$(printf '%s' "$resp" | grep -i '^x-inference-pod:' | awk '{print $2}' | tr -d '\r' || true)
  cluster=$(printf '%s' "$token" | base64 -d 2>/dev/null | cut -d/ -f2 || true)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dur=$(python3 -c "import time; print(f'{time.time() - ${start}:.3f}')")
  printf '{"ts":"%s","case":"%s","seq":%d,"http":%s,"hub_region":"%s","pod":"%s","rtt_s":%s}\n' \
    "$ts" "$CASE" "$seq" "${status:-000}" "${cluster:-none}" "${pod:-none}" "$dur" >> "${OUT}"
  sleep "${INTERVAL}"
done
