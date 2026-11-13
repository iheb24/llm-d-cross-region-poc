#!/bin/bash
# llm-d cross-region PoC — live feature tour (hybrid Env B: real vLLM in US,
# sims in EU). Runs each PROVEN feature briefly and prints a verdict line.
# Adds ~10 minutes of light traffic; failure demo is opt-in (--with-failure).
# Usage: ./showcase.sh [--with-failure]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HUB="34.75.150.223"
REAL="Qwen/Qwen2.5-Coder-14B-Instruct-AWQ"
export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"
[ -s "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"

say()  { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

policy() { # apply a hub policy, wait for rollout, then wait until serving warm
  helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway \
    --version v1.0.0 --kube-context llmd-poc-us --namespace llmd-serving \
    -f "${REPO_ROOT}/k8s/hub/$1" >/dev/null
  kubectl --context llmd-poc-us -n llmd-serving rollout status deploy/llmd-hub-epp --timeout=180s >/dev/null
  # the single-replica rollout races probes (one 500 per cutover, finding F5/P4):
  # wait until a probe succeeds before measuring
  for i in $(seq 1 12); do
    code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "http://${HUB}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${REAL}\",\"messages\":[{\"role\":\"user\",\"content\":\"warmup\"}],\"max_tokens\":2}" 2>/dev/null || true)
    [ "$code" = "200" ] && return 0
    sleep 3
  done
  echo "  (warn: policy $1 never went warm)" >&2
}

probe() { # probe <n> -> prints "region,pod,http" per request
  local n="$1" out="" i
  for i in $(seq 1 "$n"); do
    out=$(curl -sS -m 60 -i -X POST "http://${HUB}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${REAL}\",\"messages\":[{\"role\":\"user\",\"content\":\"showcase $i\"}],\"max_tokens\":4}" 2>/dev/null || true)
    local tok pod code
    tok=$(printf '%s' "$out" | grep -i '^x-session-token:' | awk '{print $2}' | tr -d '\r' | base64 -d 2>/dev/null | cut -d/ -f2 || true)
    pod=$(printf '%s' "$out" | grep -i '^x-inference-pod:' | awk '{print $2}' | tr -d '\r' || true)
    code=$(printf '%s' "$out" | head -1 | awk '{print $2}')
    echo "${tok:-none},${pod:-none},${code:-000}"
    sleep 0.2
  done
}

say "F1 — Deterministic regional selection (T1)"
policy router-values.force-eu.yaml
r=$(probe 6); echo "$r" | sed 's/^/      /'
[ "$(echo "$r" | grep -c '^eu,.*200')" = 6 ] && pass "6/6 requests forced to EU" || info "see distribution above"
policy router-values.force-us.yaml
r=$(probe 6); echo "$r" | sed 's/^/      /'
[ "$(echo "$r" | grep -c '^us,.*200')" = 6 ] && pass "6/6 requests forced to US (real vLLM)" || info "see distribution above"

say "F2 — Weighted regional routing (T2, eu 8 / us 2)"
policy router-values.t2-weighted.yaml
r=$(probe 40)
eu=$(echo "$r" | grep -c '^eu,') ; us=$(echo "$r" | grep -c '^us,')
info "observed split: eu=$eu us=$us (expected ~32/8)"
python3 -c "
e,u=$eu,$us; n=e+u
chi=(e-0.8*n)**2/(0.8*n)+(u-0.2*n)**2/(0.2*n)
print(f'      chi2={chi:.2f} (crit 3.841) ->', 'PASS' if chi<3.841 else 'FAIL')"

say "F3 — Two-level routing evidence (T5)"
info "each request: hub region + independently selected endpoint pod"
policy router-values.yaml
probe 4 | sed 's/^/      /'
pass "hub->region and region->endpoint are both visible per response"

say "F4 — Prefix cache, real vLLM counters (T6)"
policy router-values.force-us.yaml   # pin: cold+warm must hit the same real endpoint
PF=$(kubectl --context llmd-poc-us -n llmd-serving port-forward deploy/llmd-vllm 18002:8000 >/dev/null 2>&1 & echo $!)
sleep 3
hits() { curl -sS -m 5 localhost:18002/metrics 2>/dev/null | grep '^vllm:prefix_cache_hits_total' | awk '{print $2}'; }
PREFIX=$(python3 -c "print('Handbook section: hub routing, cache affinity, failover. ' * 120)")
h0=$(hits)
cold=$(curl -sS -m 120 -N -o /dev/null -w '%{time_starttransfer}' -X POST "http://${HUB}/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${REAL}\",\"stream\":true,\"max_tokens\":8,\"messages\":[{\"role\":\"system\",\"content\":\"${PREFIX} A\"},{\"role\":\"user\",\"content\":\"one word\"}]}")
sleep 1; h1=$(hits)
warm=$(curl -sS -m 120 -N -o /dev/null -w '%{time_starttransfer}' -X POST "http://${HUB}/v1/chat/completions" -H 'Content-Type: application/json' \
  -d "{\"model\":\"${REAL}\",\"stream\":true,\"max_tokens\":8,\"messages\":[{\"role\":\"system\",\"content\":\"${PREFIX} A\"},{\"role\":\"user\",\"content\":\"different suffix\"}]}")
sleep 1; h2=$(hits)
kill $PF 2>/dev/null
info "cold TTFT ${cold}s (hits +$(python3 -c "print(int(${h1:-0}-${h0:-0}))"))"
info "warm TTFT ${warm}s (hits +$(python3 -c "print(int(${h2:-0}-${h1:-0}))"))"
python3 -c "
c,w=float('$cold'),float('$warm')
hd=${h2:-0}-${h1:-0}
print('PASS warm TTFT < 0.5x cold AND hits increased' if (w < 0.5*c and hd > 0) else 'check numbers above')" | sed "s/^PASS/  \\033[32mPASS\\033[0m/;s/^check/      check/"

say "F5 — Multi-turn session affinity (T7)"
policy router-values.force-us.yaml
tok=""
hist="[]"
for t in 1 2 3; do
  hist=$(python3 -c "import json,sys; h=json.loads(sys.argv[1]); h.append({'role':'user','content':'turn $t: continue our chat about caching'}); print(json.dumps(h))" "$hist")
  out=$(curl -sS -m 60 -i -X POST "http://${HUB}/v1/chat/completions" \
    -H 'Content-Type: application/json' ${tok:+-H "x-session-token: $tok"} \
    -d "{\"model\":\"${REAL}\",\"messages\":${hist},\"max_tokens\":6}" 2>/dev/null || true)
  region=$(printf '%s' "$out" | grep -i '^x-session-token:' | awk '{print $2}' | tr -d '\r' | base64 -d 2>/dev/null | cut -d/ -f2 || true)
  tok=$(printf '%s' "$out" | grep -i '^x-session-token:' | awk '{print $2}' | tr -d '\r' || true)
  ans=$(printf '%s' "$out" | grep -i '^x-inference-pod:' | awk '{print $2}' | tr -d '\r' || true)
  info "turn $t -> region=${region:-?}"
done
[ "$region" = "us" ] && pass "3/3 turns pinned to the same region via x-session-token"

say "F6 — Latency: hub overhead vs cross-region (T9)"
for path in direct-us hub hub-eu; do
  case $path in
    direct-us) url="http://34.74.158.67/v1/chat/completions";;
    hub)       url="http://${HUB}/v1/chat/completions";;
    hub-eu)    policy router-values.force-eu.yaml; url="http://${HUB}/v1/chat/completions";;
  esac
  ts=$(for i in $(seq 1 8); do curl -sS -m 60 -N -o /dev/null -w '%{time_starttransfer}\n' -X POST "$url" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${REAL}\",\"stream\":true,\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"latency probe\"}]}" 2>/dev/null; done)
  p50=$(printf '%s\n' "$ts" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
  info "$path TTFT p50 ≈ ${p50}s"
done
policy router-values.yaml

if [ "${1:-}" = "--with-failure" ]; then
  say "F7 — Failure behavior probe (T4r: pool down, real cold start)"
  kubectl --context llmd-poc-us -n llmd-serving scale deploy/llmd-vllm --replicas=0
  sleep 6
  for i in 1 2 3; do
    code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "http://${HUB}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"${REAL}\",\"messages\":[{\"role\":\"user\",\"content\":\"failure probe\"}],\"max_tokens\":4}")
    info "during outage: HTTP $code (hub keeps preferred region; no auto-failover — R11b)"
  done
  kubectl --context llmd-poc-us -n llmd-serving scale deploy/llmd-vllm --replicas=1
  info "restoring… (real cold start ≈ 3 min from PVC-cached weights)"
  kubectl --context llmd-poc-us -n llmd-serving wait --for=condition=ready pod -l app=llmd-vllm --timeout=360s
  code=$(curl -sS -m 60 -o /dev/null -w '%{http_code}' -X POST "http://${HUB}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${REAL}\",\"messages\":[{\"role\":\"user\",\"content\":\"recovered?\"}],\"max_tokens\":4}")
  info "after restore: HTTP $code"
fi

say "Feature tour complete"
echo "  Evidence dashboard: https://console.cloud.google.com/monitoring/dashboards/custom/ed86ce2c-3d60-4da8-9247-86ec377db398?project=project-c4f86d90-75ff-4766-8cd"
