#!/bin/bash
# T3 — preferred region with overflow (Env B-hybrid).
# Default hub policy (queue+KV scorers, max-score picker) tie-pins US (real).
# Saturate the single US L4 with parallel load; expect the hub's
# multicluster-queue-scorer to flip traffic to EU (sim) once the US queue
# grows; expect return to US after load stops. Records:
#   probe JSONL (per-2s hub requests) + queue-scrape JSONL (US EPP aggregates).
# Usage: ./t3-overflow.sh <out-dir>
set -uo pipefail

OUTDIR="${1:?out-dir}"
HUB_IP="136.108.168.11"
REAL="Qwen/Qwen2.5-Coder-14B-Instruct-AWQ"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUTDIR"

# --- metrics scraper (US regional EPP via local port-forward; the ILB is
#     VPC-internal and unreachable from the operator machine) -------------------
kubectl --context llmd-poc-us -n llmd-serving port-forward svc/llmd-router-epp 19093:9090 >/dev/null 2>&1 & PF=$!
sleep 3
( while true; do
    m=$(curl -sS -m 5 http://localhost:19093/metrics 2>/dev/null)
    q=$(printf '%s' "$m" | grep '^llm_d_epp_average_queue_size' | awk '{print $2}')
    kv=$(printf '%s' "$m" | grep '^llm_d_epp_average_kv_cache_utilization' | awk '{print $2}')
    rr=$(printf '%s' "$m" | grep '^llm_d_epp_average_running_requests' | awk '{print $2}')
    printf '{"ts":"%s","us_avg_queue":%s,"us_kv_util":%s,"us_running":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${q:-null}" "${kv:-null}" "${rr:-null}" >> "$OUTDIR/t3-queue.jsonl"
    sleep 3
  done ) & SCRAPE=$!

MODEL="$REAL" "${REPO_ROOT}/tests/probe-loop.sh" "${OUTDIR}/t3-probes.jsonl" 2 t3-overflow & PROBE=$!
sleep 15

echo "BASELINE-END $(date -u +%H:%M:%SZ) — starting load (12 workers x 120s (v3: usage-limit 0.15))"
PROMPT=$(python3 -c "print('Explain distributed consensus in depth. ' * 150)")
for w in $(seq 1 12); do
  ( end=$((SECONDS + 120)); while [ $SECONDS -lt $end ]; do
      curl -sS -m 60 -o /dev/null -X POST "http://${HUB_IP}/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${REAL}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT} w${w}\"}],\"max_tokens\":256}" 2>/dev/null || true
    done ) &
done
LOAD_PIDS=$(jobs -p)
sleep 120
echo "LOAD-END $(date -u +%H:%M:%SZ) — waiting for workers to drain"
wait $LOAD_PIDS 2>/dev/null
echo "RECOVERY window 60s"
sleep 60
kill $PROBE $SCRAPE $PF 2>/dev/null; wait 2>/dev/null

echo "==> T3 summary"
python3 - "$OUTDIR" <<'EOF'
import json, sys, itertools
outdir = sys.argv[1]
probes = [json.loads(l) for l in open(f"{outdir}/t3-probes.jsonl")]
met = [json.loads(l) for l in open(f"{outdir}/t3-queue.jsonl")]
print("probes:", len(probes))
for k, g in itertools.groupby(probes, key=lambda r: (r['http'], r['hub_region'])):
    g = list(g)
    print(f"  {g[0]['ts'][11:19]}..{g[-1]['ts'][11:19]} http={k[0]} region={k[1]} n={len(g)}")
kv = [m['us_kv_util'] for m in met if m.get('us_kv_util') is not None]
print(f"US kv_util: min={min(kv):.2f} max={max(kv):.2f}" if kv else "no kv samples")
q = [m['us_avg_queue'] for m in met if m.get('us_avg_queue') is not None]
print(f"US avg_queue max: {max(q) if q else 'n/a'}")
first_eu = next((p['ts'] for p in probes if p['hub_region'] == 'eu'), None)
print("first EU-served probe:", first_eu)
if first_eu:
    before = [m for m in met if m['ts'] <= first_eu]
    if before:
        m = before[-1]
        print("metrics just before flip:", {k: m[k] for k in ('us_avg_queue','us_kv_util','us_running')})
slow = [p for p in probes if float(p['rtt_s']) > 3]
print(f"probes with rtt>3s: {len(slow)}")
EOF
