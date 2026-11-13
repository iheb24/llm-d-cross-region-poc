# llm-d Cross-Region PoC — Final Report

Date: 2026-11-13 (sessions of 2026-11-11 → 11-13). Author state: evidence archived in `docs/results/`; this document is the evaluation summary against the PoC's own success definition (PLAN.md §1).

## Verdict by success criterion

| # | Criterion (PLAN.md §16) | Verdict | Evidence |
|---|---|---|---|
| 1 | Deliberate EU/US regional selection | **Demonstrated** | T1: 20/20 forced EU + 20/20 forced US; per-request hub decision + endpoint correlation (`results/p4`) |
| 2 | Preferred-region overflow on measured pressure | **Demonstrated with a synthetic pressure signal** | T3: 8/8 US at rest → 42/42 EU under pressure → 24/24 US after reset; flip ≤9 s, recovery ≤3 s, 74/74 HTTP 200, no oscillation (`results/p6/t3s-*.jsonl`). Caveat: pressure = sim fake-metrics ramp; the routing chain is real. Organic trigger at PoC scale: not reproducible (see limitations) |
| 3 | Predictable behavior under injected regional failures | **Demonstrated (measured, incl. negative findings)** | T4: gateway-down ~34 s detect/~23 s recover (14×503); pool-down 87×503 over 3.5 min, real cold start 3m04s; regional-EPP-down = fail-closed 500; metrics-outage = data plane unaffected (48/48) |
| 4 | Provable hub→region→endpoint decision chain | **Demonstrated** | T5: both decisions per request (`x-session-token` cluster + `x-inference-pod`); negative control (EPP-down removes the evidence) |
| 5 | Latency overhead: direct / local-hub / cross-region-hub | **Measured** | T9 (Paris client, N=25): direct-US TTFT p50 0.306 s; hub→US p50 0.307 s (hub ≈ +1 ms); hub→EU p50 0.303 s vs direct-EU 0.029 s (+274 ms ≈ two transatlantic legs) |
| 6 | Session/prefix affinity + actual vLLM cache reuse | **Demonstrated with serving counters** | T6: cold 3.09 s (hits +0) → warm 0.42 s (hits +4096, 7.2×); T7: 3/3 pinned turns, 84–87 % tokens reused/turn, migration cold, return warm-again (81 %) |
| 7 | Limitations documented; unsupported claims absent | **Done** | See below |

## Limitations and non-claims (the honest half of the report)

1. **No automatic hub failover exists in llm-d v1.0.0 multicluster** (finding R11b): the hub's aggregate signals (queue/KV) cannot distinguish "idle" from "pool down" — measured: 25 consecutive 503s to a dead pool (sim) and 87 (real stack) with a healthy region available. Adoption would require an added readiness/health signal at hub scope.
2. **T3's organic trigger did not occur at PoC scale** despite 10+ mechanism attempts: vLLM's continuous batching absorbs 16-way load (`num_requests_waiting` stays 0; KV util peaked ~0.08); llm-d flow control is **feature-gated OFF by default** in v1.0.0; per-priority-band caps did not clamp dispatch in our config (open question). The queue-driven overflow mechanism itself was then demonstrated with a synthetic pressure ramp.
3. **Single GPU project-wide** (`GPUS_ALL_REGIONS = 1`, increase refused): all dual-GPU claims are out of scope; regional pod-level selection is proven on sims only (Env A).
4. **Tie behavior**: with equal scores, `max-score-picker` pins 100 % to one cluster *and the pin direction changes across EPP restarts*; with live attributes on both clusters, exact ties split randomly. Any "preferred region" needs explicit weights.
5. **Rollout transient**: single-replica EPP config swaps cost ~1 failed request at cutover. Test tooling must wait-for-warm after policy changes (built into `tests/showcase.sh`).
6. **v1.0.0 multicluster plugins are StabilityAlpha** (hub runs `--allow-experimental-plugins`); no backwards-compat guarantee.
7. **Security posture (Env A/B shortcuts, documented):** hub→spoke data plane is plain HTTP to the regional gateway IPs (GCP backbone encrypts inter-DC traffic at L3; synthetic prompts only); cross-cluster metrics over VPC NodePort, no mTLS (ILB VIPs proved region-local; mTLS is upstream-native via #1858/#1918 but untested here). Not production postures.
8. **Regional EPP pod-metrics scrape went stale once after a Spot preemption** (new pod IP; aggregates stuck at 0 until the EPP restarted; zero poll errors surfaced). Seen once; if it reproduces, file upstream.
9. Sim identity headers (`x-inference-pod`) are sim-emitted; real vLLM responses carry no pod identity (single endpoint/region made this unambiguous here; at >1 real endpoint/region, correlation must come from EPP decision metadata).

## Environments used

- **Env A** (functional): 2 sims/region, hub in US — T1, T2, T5, T4-sim.
- **Env B-hybrid** (2026-11-12 adaptation): real vLLM (Qwen2.5-Coder-14B-AWQ, pinned revision `eb3172f`, `--enforce-eager`, spot g2-standard-4) in US + 2 sims in EU — T3, T4-real, T6, T7, T9.

## Costs (actuals, operator-observed)

- Idle stack: 2 × e2-standard-4 ≈ 2 × $0.134/h ≈ **$0.27/h** + IPs/GMP small.
- Real-inference windows: + spot g2-standard-4 ≈ **$0.25/h** (warm during test windows only).
- Two full teardowns verified zero-residue (incl. leaked NEGs/PVCs swept); rebuild ~40 min scripted.
- WAN egress: small (test traffic only); not separately billed out in this PoC.

## What would change the remaining answers

- `GPUS_ALL_REGIONS ≥ 2` → rerun original Env B (both regions real) for dual-GPU T3/T9.
- Deeper load (64+ concurrent × long outputs) or detector-threshold tuning → organic T3 trigger.
- KEDA phase (P7, optional): requires `featureGates: ["flowControl"]` on the regional EPP (F2) — K1 forced-cold activation is the first gate.

## Component versions (frozen in `versions.lock`)

llm-d v1.0.0 (router EPP image+charts), vLLM v0.30.0, GAIE/Gateway API v1.6.2, Envoy Gateway v1.8.1 + AI Gateway v0.7.0, inference-sim v1.0.0, model `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ@eb3172f`, GKE v1.36.4.
