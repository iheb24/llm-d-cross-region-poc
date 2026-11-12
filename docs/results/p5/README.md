# P5 evidence — Environment B-hybrid: real inference (2026-11-12)

## Design constraint (why hybrid)

`GPUS_ALL_REGIONS = 1` **globally** — only one L4 VM can exist project-wide; quota increase to ≥2 requested and **refused by GCP** (2026-11-11). The PoC runs the single real endpoint in the US cluster (hub-colocated); EU stays on 2 sims. Claims boundaries are in PLAN.md §P5. Capacity note: L4 exhausted across 10+ zones on 2026-11-11; working zones found by direct probe: `europe-west1-b` (EU), `us-east1-c` (US) — clusters now live there.

## Deployed (this run)

- EU `europe-west1-b`: gateway `104.155.26.156`, regional EPP v1.0.0, 2 sims (ctx 8192 — default 1024 broke long prefixes).
- US `us-east1-c`: gateway `34.74.158.67`, hub gateway `136.108.168.11`, regional EPP, hub EPP, 2 sims (control/fallback, out of pool), **1× real vLLM v0.30.0** on spot g2-standard-4 L4, model `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ@eb3172f…`, `--enforce-eager` (16 GB node OOMs under torch.compile), prefix caching on.
- Incidents fixed en route (all codified): GPU `nvidia.com/gpu` toleration, `strategy: Recreate` (one GPU), liveness-probe `initialDelaySeconds: 600` (multi-minute init), EPP 500m CPU override, sim context size.

## Validation

| Check | Result |
|---|---|
| EU direct-spoke (sim) | HTTP 200, 52 ms from Paris |
| US direct-spoke (real vLLM, streaming) | HTTP 200, streamed; TTFT 0.23 s warm engine |
| Hub → US real (Qwen model) | HTTP 200, `hub_region=us` |
| Hub → EU sim | HTTP 200, `hub_region=eu` |
| Hub with sim model pinning US real pool | HTTP 404 — **hybrid asymmetry: model catalogs differ per region; hub has no per-model eligibility (recorded caveat)** |
| EPP pool view (US) | `ready_endpoints=1`, endpoint `llmd-vllm-…-rank-0` |
| vLLM metrics | `vllm:prefix_cache_queries_total` / `…_hits_total` live and scrapeable |

## T6 — exact prefix-cache behavior: PASS (real counters)

Fresh 2418-word (~3.3k-token) prefix, forced policies, streamed TTFT, counters read from the serving vLLM (`docs/results/p5/t6-hybrid.jsonl`):

| Step | Region | TTFT | `queries` delta | `hits` delta |
|---|---|---|---|---|
| Cold (fresh prefix) | US (vLLM) | **3.082 s** | +4114 | **+0** — cold confirmed |
| Warm (same prefix, new suffix) | US (vLLM) | **0.420 s** (0.136× cold) | +4111 | **+4096** — real prefix-cache hit |
| Cold-reference | EU (sim) | 0.604 s → warm 0.493 s (0.815×) | n/a (sim semantics) | n/a |

Pass per PLAN.md §10/T6: cache-hit counters increase on reuse, warm/cold TTFT compared at equivalent input lengths and controlled output (max_tokens 8), complete route evidence, fresh prefixes. Caveat: cross-region cold/warm with real counters requires a second GPU (recorded as not provable in hybrid; the EU leg documents sim reference behavior instead).

## Evidence caveats (hybrid)

1. `x-inference-pod`/`x-session-token` response headers are **sim-emitted** (sim's POD_NAME env); real vLLM responses carry `x-went-into-resp-headers` (EPP marker) but no pod identity — with 1 endpoint/region identity is unambiguous; the hub's `x-session-token` (cluster identity) still appears on hub-routed responses.
2. Cross-region path latency = real WAN hop + sim inference (sim latency deterministic; WAN component isolable in T9 by subtracting sim-direct baselines).
3. vLLM runs `--enforce-eager` — latency numbers labeled "eager" (torch.compile OOMs on 16 GB g2-standard-4).

## G3 status

Exit criteria per PLAN.md §P5 (adapted): real TTFT/streaming on direct-spoke-US and via-hub paths ✅; T6 pass with serving-metric confirmation ✅. **Recommend G3 PASS (hybrid).** GPU pool stays warm (min 1, spot) for P6; scale to 0 on your word.
