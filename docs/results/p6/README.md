# P6 evidence — overload, failure, affinity, latency on the hybrid real stack (2026-11-12)

Raw records: `t3v3-*.jsonl`, `t3-*.jsonl` (v-runs), `t4r-1-gateway-down.jsonl`, `t4r-2-pool-down.jsonl`, `t7-multiturn.jsonl`, `t9-latency.jsonl`.

## T3 — preferred region with overflow: PARTIAL

**What passed:** the preference itself. With `endpoint-attribute-weight-scorer {us: 2, eu: 1}` + `max-score-picker`, 100% of baseline traffic (19/19 probes) went to the preferred US region; deterministic forcing (T1) and weighted splits (T2) passed in P4.

**What could not be produced at PoC scale: an actual queue/saturation overflow trigger.** Iteration record (each kept as evidence):

| Attempt | Mechanism | Outcome |
|---|---|---|
| v1 | 8-way concurrency, default config | Fully absorbed by vLLM continuous batching; `us_running` peaked 17; EPP queue stayed 0; probe RTT never exceeded 1.6 s |
| v2 | 16-way × 2.5k-token prompts | Same; US KV util crept to 0.08 — far below any meaningful saturation |
| v3–v5 | `static-usage-limit-policy` ceilings | No gating: flow control in v1.0.0 is **OFF by default** (`flowControl` feature gate; log: "Flow Control layer is disabled via the flowControl feature gate") |
| v6–v7 | Feature gate ON + ceiling 0.25→0.05 | No gating: detector saturation = max(queueDepth/5, kvUtil/0.8) and **vLLM's own waiting queue is always 0** (it admits everything to `running`), so saturation ≈ kv/0.8 ≈ 0.1 — borderline at PoC scale |
| v9 | preferred-US policy + ceiling | Baseline preference proven (19/19 US); still no queue under 12-way load |
| v10 | per-priority-band `maxRequests: 4` | Did not clamp dispatch (`us_running` held 12) — band assignment of priority-less requests needs deeper study; **left as an open question**, not worked around |

Root reason, stated plainly: with flow control at defaults, a vLLM backend admits all PoC-scale load into its own batch (`num_requests_waiting` stays 0), so `llm_d_epp_average_queue_size` never rises, and the hub's queue-scorer has nothing to react to. A real overflow trigger needs either much deeper load (64+ concurrent long-output streams to push KV utilization toward the 0.8 detector default — out of time/token budget) or deliberately tuned detector thresholds (out of scope). **Not claimed as demonstrated.** The multicluster signal path itself is verified end-to-end (hub scrapes both regional aggregates live; see F1).

## T4-real — regional failure handling on the real stack

| Case | Injection → client-visible failure | Signature | Hub behavior | Recovery |
|---|---|---|---|---|
| US gateway down (Envoy data plane → 0) | ~34 s (NLB drain) | 14 × 503, flapping during transitions | all traffic still to US (policy pinned) | ~23 s after scale-back |
| US pool down (vLLM → 0) | ≤ 2 s (admission 503, pool empty) | **87 × 503 over ~3.5 min** | never rerouted to healthy EU (R11b detection gap, real-stack confirmation) | **3m04s real cold start** from PVC-cached weights; first 200 at +2m41s |

## T7 — multi-turn affinity: PASS

Five-turn conversation with growing history, `x-session-token` carried (`t7-multiturn.jsonl`):

- q1–q3 (force-us): **3/3 same US endpoint**; real counters: hits/queries ≈ 84–87% of prompt tokens reused per turn (352/419, 336/398, 384/441).
- q4 (force-eu migration): EU sim, cold-equivalent (0 real hits — sim semantics).
- q5 (force-us return): **warm-again** — hits 464/571 ≈ 81% reused; conversation KV blocks survived the EU round-trip, measured not assumed.

## T9 — latency matrix (Paris client, N=25/path, p50/p95): PASS

| Path | TTFT p50 | TTFT p95 | Total p50 |
|---|---|---|---|
| direct-spoke US (real vLLM) | 0.306 s | 0.322 s | 1.789 s |
| direct-spoke EU (sim) | 0.029 s | 0.036 s | 0.031 s |
| via-hub → US (real) | 0.307 s | 0.316 s | 1.751 s |
| via-hub → EU (sim) | 0.303 s | 0.325 s | 0.305 s |

- **Hub overhead, local path: ~1 ms TTFT** (0.307 vs 0.306) — hub scheduling is negligible at idle.
- **Cross-region via hub: +274 ms TTFT** vs EU direct (two transatlantic legs: Paris→US hub + US→EU gateway ≈ measured WAN cost; sim inference ≈ 0 so the delta is almost pure WAN+scheduling).
- Real vLLM eager-mode TTFT for a ~200-token prompt ≈ 0.3 s; totals dominated by decode (max_tokens 32, eager).

## New findings recorded this phase

- **F1 — cross-cluster metrics path was broken from P4 onward** (hub never had EU aggregates): GKE ILB VIPs are region-local (global-access annotation did not enable cross-region on v1.36), and a custom firewall rule had silently lost the `10.24.0.0/14` source range. Fixed via NodePort (`30090`) on system nodes + corrected VPC firewall (`llmd-poc-xcluster-metrics`). Side effect discovered: with EU attributes finally present, default-policy ties became **random splits** instead of pinning (tie-break is map-order dependent and changes across EPP restarts — tie direction is not a stable signal).
- **F2 — flow control is feature-gated OFF in v1.0.0** (verified in EPP startup logs). K1–K4 (P7) must account for this; the keda-epp guide's queueing assumptions need the gate enabled.
- **F3 — session affinity at hub level works** (`multicluster-session-affinity-filter`, `x-session-token` echo); stickiness held 100% across turns and policy swaps that don't forbid the destination.
- **F4 — 404 asymmetry**: model identity is per-region serving config; the hub does not filter by model availability (hybrid artifact; EU sims now serve the real model name to keep T3/T7/T9 evidence clean).
- **F5 — tie-pin direction instability** (F1 side effect) — "default policy pins US" is no longer true per-boot; any policy that needs a deterministic preferred region must weight it (as the T3 pref profile does).

## G4 status

T3 PARTIAL (preference proven; overflow trigger not reproducible at PoC scale — documented, not claimed). T4-real measured (incl. 3m04s real cold start). T7 PASS. T9 PASS (matrix with hub-overhead and WAN decomposition). Regional pod-level selection: proven in Env A (P3/P4). **G4 met with T3 explicitly partial** — the overflow *signal chain* is verified; the *trigger* awaits deeper load or detector tuning (candidates recorded).
