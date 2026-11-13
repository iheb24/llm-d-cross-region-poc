#!/bin/bash
# T3 — preferred-region overflow, synthetic-pressure edition (Env B-hybrid).
# Hub policy: t3-pref-us (US preferred via weights; queue+kv scorers live).
# Pressure: the US in-pool pressure-sim ramps vllm:num_requests_waiting 0->24,
# raising the regional aggregate llm_d_epp_average_queue_size; the hub's
# multicluster-queue-scorer flips traffic to EU. Ramp to zero -> recovery.
# Evidence: probes (region per 2s) + regional aggregate timeline.
# CAVEAT: the queue pressure is synthetic (sim fake-metrics); the routing
# mechanism chain (regional aggregate -> hub scorer -> flip -> recovery) is real.
set -uo pipefail
OUTDIR="${1:?out-dir}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$OUTDIR"

kubectl --context llmd-poc-us -n llmd-serving port-forward deploy/llmd-pressure-sim 18011:8000 >/dev/null 2>&1 & PF_SIM=$!
kubectl --context llmd-poc-us -n llmd-serving port-forward svc/llmd-router-epp 19103:9090 >/dev/null 2>&1 & PF_EPP=$!
sleep 4

( while true; do
    q=$(curl -sS -m 5 http://localhost:19103/metrics 2>/dev/null | grep '^llm_d_epp_average_queue_size' | awk '{print $2}')
    printf '{"ts":"%s","us_avg_queue":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${q:-null}" >> "$OUTDIR/t3s-queue.jsonl"
    sleep 3
  done ) & SCRAPE=$!

MODEL="Qwen/Qwen2.5-Coder-14B-Instruct-AWQ" "${REPO_ROOT}/tests/probe-loop.sh" "$OUTDIR/t3s-probes.jsonl" 2 t3-synth & PROBE=$!
sleep 12

echo "BASELINE-END $(date -u +%H:%M:%SZ) — ramping US queue 0->24 over 60s"
curl -sS -m 10 -X POST localhost:18011/admin/config -H 'Content-Type: application/json' \
  -d '{"fake-metrics":{"waiting-requests":"ramp:0:24:60s"}}' -o /dev/null -w 'ramp: %{http_code}\n'
sleep 110
echo "HOLD-END $(date -u +%H:%M:%SZ) — resetting pressure to 0"
curl -sS -m 10 -X POST localhost:18011/admin/config -H 'Content-Type: application/json' \
  -d '{"fake-metrics":{"waiting-requests":0}}' -o /dev/null -w 'reset: %{http_code}\n'
sleep 60
kill $PROBE $SCRAPE $PF_SIM $PF_EPP 2>/dev/null; wait 2>/dev/null

echo "==> T3-synth summary"
python3 - "$OUTDIR" <<'EOF'
import json, sys, itertools
outdir = sys.argv[1]
probes = [json.loads(l) for l in open(f"{outdir}/t3s-probes.jsonl")]
queue = [json.loads(l) for l in open(f"{outdir}/t3s-queue.jsonl")]
print("probes:", len(probes))
for k, g in itertools.groupby(probes, key=lambda r: (r['http'], r['hub_region'])):
    g = list(g)
    print(f"  {g[0]['ts'][11:19]}..{g[-1]['ts'][11:19]} http={k[0]} region={k[1]} n={len(g)}")
q = [m['us_avg_queue'] for m in queue if m.get('us_avg_queue') is not None]
print("us_avg_queue min/max:", (min(q), max(q)) if q else 'none')
first_eu = next((p['ts'] for p in probes if p['hub_region'] == 'eu'), None)
back_us = next((p['ts'] for p in reversed(probes) if p['hub_region'] == 'us'), None)
print("first EU probe:", first_eu, "| last US probe:", back_us)
EOF
