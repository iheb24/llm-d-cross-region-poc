# P4 evidence — hub routing on Environment A (2026-11-11)

Hub: `llmd-hub` release (EPP v1.0.0, `--allow-experimental-plugins`, `--emit-endpoint-scores`) in the US cluster; candidates = both regional gateways via `multicluster-file-discovery` (`k8s/hub/clusters.yaml`); pool aggregates scraped from regional EPPs over VPC-internal ILBs (`10.10.0.100` / `10.20.0.100`, scheme http — Env-A containment; mTLS is deferred hardening). Hub gateway `llmd-hub-gateway` PROGRAMMED at `146.148.64.26` (per-Gateway `EnvoyProxy` via `infrastructure.parametersRef`; Gateway API v1 has no namespace field there — EnvoyProxy must live in the Gateway's namespace).

Raw run records: `t1-force-eu.jsonl`, `t1-force-us.jsonl`, `t2-weighted.jsonl`, `t4-2-pool-down.jsonl`, `t4-2a-forced-eu-pool-down.jsonl`, `t4-2b-default-us-pool-down.jsonl`, `t4-4-metrics-down.jsonl`, `t4-1-gateway-down.jsonl`.

## T1 — deterministic regional selection: PASS

| Policy | Requests | HTTP 200 | In forced region | Regional pod spread |
|---|---|---|---|---|
| force-eu (label-selector-filter `region=eu`) | 20 | 20 | **20/20 EU** | 9/11 across both EU sims |
| force-us | 20 | 20 | **20/20 US** | 8/12 across both US sims |

Forcing is hub config (`helm upgrade` config swap) — no client request fields, per A9.

## T2 — weighted regional routing: PASS

Policy: `label-producer` (discovery label `region` → attribute) → `endpoint-attribute-weight-scorer` {eu: 8, us: 2} → `weighted-random-picker`. N=200, criterion fixed pre-run (chi-square, p=0.05):

- Observed **159 eu / 40 us** (199 HTTP 200; 1 rollout-race 500) vs expected 159.2/39.8 → chi2 ≈ 0.00 → **PASS**.
- Regional level independently spread: EU pods 81/78, US pods 21/19.

## T5 — two-level routing: PASS (incl. negative control)

Every record carries the hub decision (decoded `x-session-token` = `llmd-poc/<region>`) **and** the independently selected regional pod (`x-inference-pod`). T1/T2 tables show both levels varying independently (hub pins region; regional EPP spreads across the two sims).

Negative control (what "no regional EPP" looks like):
1. A `/bypass` HTTPRoute straight to the sim Service did **not** bypass the regional EPP — the gateway's ext-proc (GAIE) runs per-gateway, so the EPP still selected endpoints (headers present). Deleted; recorded as a wiring fact.
2. Regional EPP scaled to 0 → regional gateway returns **500 on every request** (see below) — proving the evidence headers (`x-inference-pod`, regional session token) exist only when the regional EPP is in the path. Recovery ~50 s (rollout + ext-proc reconnect ≤ 20 s after ready).

## T4-sim — failure injection (sim env)

| Case | Setup | Injection → client-visible failure | Failure signature | Hub behavior during outage | Recovery |
|---|---|---|---|---|---|
| T4.1 gateway down | force-eu; scale EU Envoy data plane 0 | ~12 s (NLB drain) | 24 × 503, fast (no hang; rtt flat) | keeps sending EU (forced); no alternative | ~12 s after scale-back (24 503s, then 200 at +12 s) |
| T4.2a pool down, forced | force-eu; EU sims → 0 | ≤ 2 s | 24 × 503 (`pool empty → ServiceUnavailable`) | pinned by filter — 100% to EU by design | 3 s (14:46:37 → 14:46:40) |
| T4.2b pool down, default | default policy; US sims → 0 (hub had pinned US) | ≤ 3 s | 25 × 503 over ~60 s | **never rerouted to healthy EU** — pool-down is invisible to the hub's queue/KV aggregates (both read ~0 = "idle") | ~4 s (14:49:04 → 14:49:08) |
| T4.4 metrics path down | force-eu; delete EU metrics ILB | — | none | 48/48 requests still 200 to EU — data plane independent of telemetry plane. (Pre-window note: seq 1 in the raw file is a single HTTP 500 from the policy-rollout warmup before injection, not part of the 48/48 window.) | scrape restored on ILB recreate |

T4.5 (recovery) is embedded above; no route flapping observed in any case. T4.3 (hub→spoke path interruption via firewall) deferred to P6 — T4.1 exercises the same transport failure signature.

## Findings (feed PLAN.md risks and P6 design)

1. **Tie-pinning:** with equal scores (both regions idle), `max-score-picker` deterministically pins ALL traffic to one cluster (US in every run). The default policy does not spread; spreading requires `weighted-random-picker` (T2) or asymmetric load. T3's overflow design must start from this.
2. **Hub detection gap (core PoC result):** the multicluster signal set (`llm_d_epp_average_queue_size`, `…_kv_cache_utilization`) cannot distinguish "idle" from "pool down" — both read ~0. There is no request-outcome feedback at hub level in v1.0.0's multicluster plugin family. Under the default policy the hub kept sending 25 requests to a dead pool. A production hub needs an added readiness/health signal (custom scorer input, readiness gate, or gateway-level outlier detection) — recorded as a limitation, not worked around.
3. **Regional EPP down = fail-closed (500)** with Envoy AI Gateway, despite `inferencePool.failureMode: FailOpen`. Upstream's fail-open (#3433) is a standalone-proxy feature only (G1 item 6 anticipated this split). Ext-proc reconnect after EPP restore takes ≤ ~20 s post-ready.
4. **Metrics/data-plane independence:** total telemetry loss does not disturb request flow (and, symmetrically, a healthy telemetry plane does not imply a healthy pool — finding 2).
5. **Rollout transient:** every hub EPP config swap costs ~1 failed request at the cutover (single-replica Recreate-style rollout). Test runs must pre-warm after policy changes; recorded in all raw files (one 500 at each rollout).
6. **Per-Gateway EnvoyProxy via `infrastructure.parametersRef` works** (hub IP bound independently of the class-level regional binding).

## G2 status

G2 requires: deterministic routing PASS (T1), weighted PASS (T2), two-level PASS (T5), initial failure tests recorded (T4-sim). **All met → recommend G2 PASS**, with findings 1–3 carried as documented limitations into P6 (which re-runs T3/T4/T7/T8/T9 on the real GPU stack).
