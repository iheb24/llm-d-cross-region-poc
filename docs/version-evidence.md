# G1 — Version and Architecture Validation Evidence Pack

Date: 2026-11-11. Method: source inspection of the pinned tags (read-only clones in `/tmp/llm-d-research`, deleted after P1) plus upstream release docs. Every claim below cites the pinned source; live-behavior residuals are explicitly assigned to later phases rather than assumed.

Pinned anchor: **llm-d v1.0.0** (umbrella release 2026-10-19); router source tag `v1.0.0` = commit `b9393d1a9f1d5a72ecd86f8d2b643ab54c2a9b92`. GitHub permalinks below use the `v1.0.0` tag of `llm-d/llm-d-router` and the `release-1.0` branch of `llm-d/llm-d`.

---

## Item 1 — Containment of the multicluster work in v1.0.0 — PASS

The multicluster plugin family merged as PR [llm-d-router#2232](https://github.com/llm-d/llm-d-router/pull/2232) (merge commit `38e3412cdcb55ed78560af1ed921bb97f51f3f21`, 2026-08-04; "Fixes #2244").

Local verification (recorded output):

```
$ git tag --contains 38e3412cdcb55ed78560af1ed921bb97f51f3f21 | sort -V
v0.10.0
v0.10.0-rc.1
v0.11.0
v0.11.0-rc.1
v0.11.0-rc.2
v1.0.0
v1.0.0-rc.1
v1.0.0-rc.2
```

→ contained in router `v1.0.0`. Epic tracking: [llm-d-router#1907](https://github.com/llm-d/llm-d-router/issues/1907) (hub mode; shipped items #2147, #1858, #1918, #2244).

## Item 2 — Multicluster plugin presence and exact names — PASS

All eight plugin types exist at tag `v1.0.0` and are registered in `cmd/epp/runner/runner.go` (L722–812) — **all at `StabilityAlpha`**:

- Scheduling: `multicluster-queue-scorer`, `multicluster-kv-cache-utilization-scorer`, `multicluster-session-affinity-filter`, `multicluster-prefix-cache-scorer`
- Request control: `multicluster-approx-prefix-cache-producer`
- Datalayer: `multicluster-file-discovery`, `multicluster-metrics-data-source`, `multicluster-metrics-extractor`

Release-truth attribute keys (`pkg/epp/framework/plugins/datalayer/attribute/metrics/data_types_multicluster.go`): `llm-d.ai/multicluster-kv-cache-utilization`, `llm-d.ai/multicluster-queue-size` (supersedes the epic text's `llm-d.ai/pool-*` spellings). Scraped spoke metrics: `llm_d_epp_average_kv_cache_utilization`, `llm_d_epp_average_queue_size` (extractor defaults, overridable via `kvCacheUtilizationMetric`/`queueSizeMetric`); both are exported by the EPP itself (`pkg/epp/metrics/llm_d_router_metrics.go` L184–193).

**Consequences:** (a) the hub EPP must run with `--allow-experimental-plugins` (chart flags; enforced at load otherwise); (b) alpha stability = no backwards-compat guarantee → PoC pins exactly, records behavior, and revalidates on any version change (risk R15); (c) per-plugin Prometheus metrics of the delegating variants report under the *stock* type label (plugins README) — observability queries must use stock names.

References: [plugins README §Multi-cluster variants](https://github.com/llm-d/llm-d-router/blob/v1.0.0/pkg/epp/framework/plugins/README.md), [runner.go](https://github.com/llm-d/llm-d-router/blob/v1.0.0/cmd/epp/runner/runner.go).

## Item 3 — Hub config surface (deterministic, weighted, queue-based; config swap) — PASS

Config kind: `EndpointPickerConfig`, `apiVersion: llm-d.ai/v1`, loaded via EPP flag `--config-file` (`cmd/epp/runner/runner.go` L837). Chart surface (`config/charts/routerlib`): `router.epp.pluginsConfig` (structured) / `pluginsCustomConfig` (raw files). **Config swap = `helm upgrade` → EPP rollout restart** (no in-place EPPConfig reload; the discovery file hot-reloads via `watchFile: true`, fsnotify — `datalayer/discovery/file/plugin.go`).

Mechanisms verified in source:

- **Deterministic regional selection (T1, A9 resolved):** cluster endpoints carry labels from the discovery file; label/attribute filters (e.g., `endpoint-attribute-filter`, `bylabel` family) restrict candidates to `region=eu|us`. Forcing = swap hub EPPConfig via Helm — *not* request fields: v1.0.0 removes client-supplied screening/routing headers before forwarding (`pkg/epp/handlers/request.go` L110 `unsetRoutingHeaders`, #3090).
- **Weighted routing (T2, A8 resolved):** `endpoint-attribute-weight-scorer` (type confirmed in `scheduling/scorer/attributeweight/attributeweight.go`: `attributeKey` + positive-float `weights` map + mandatory `producer`) assigns static per-region scores; `weighted-random-picker` (type `weighted-random-picker`, `scheduling/picker/weightedrandom/picker.go`) samples proportional to score → allocation converges to weights statistically (T2 tolerance method applies).
- **Queue/load overflow (T3):** `multicluster-queue-scorer` scores min-max normalized across cluster candidates — shortest queue = 1, longest = 0, equal = 1, missing attribute = unscored (`scheduling/scorer/queuedepth/multicluster.go`). There is **no absolute-threshold plugin at hub level**: "saturation" is relative, so T3 defines its pressure condition operationally (measured `llm_d_epp_average_queue_size` + regional flow-control behavior, item 7) and states it before the run.
- Dependency validation: a config with the metric scorers but without source+extractor **fails at load** (plugins README; `Consumes()` declarations, #2287).

Draft produced: `k8s/hub/epp-config.yaml` + `k8s/hub/clusters.yaml` (committed, not applied). Residual: exact `schedulingProfiles` weight syntax validated on a live hub at P4.

## Item 4 — Cluster-scoped session and prefix affinity — PASS

- `multicluster-session-affinity-filter` delegates to the stock filter (`scheduling/filter/sessionaffinity/`): strategies `encoded_endpoint_header` (default; EPP echoes the picked endpoint in a response header, client returns it; default request header **`x-session-token`**, `scheduling/util/sessionaffinity/header.go`) and `session_id`. Session identity is client-supplied via header; `x-session-token` is not a stripped routing header (item 10). → T7 mechanics defined at both levels (stock regional filter in `k8s/region/epp-config.yaml`).
- `multicluster-prefix-cache-scorer` + `multicluster-approx-prefix-cache-producer` delegate to the stock prefix plugins; the approx indexer keys on endpoint identity, so pointing it at cluster endpoints tracks `(cluster, block)` (PR #2232 description; source `scheduling/scorer/prefix/multicluster.go`, `requestcontrol/dataproducer/approximateprefix/multicluster.go`).
- Load-vs-affinity decisions are observable: `llm_d_epp_prefix_cache_affinity_filter_decisions_total` "surfaces whether scheduling decisions were guided by cache affinity or overridden by load gates" (`docs/operations/observability/router-metrics.md` @ release-1.0) → T8 evidence channel.

Residual: affinity-state persistence/TTL parameters tuned at P4/P6; documented behavior recorded per run.

## Item 5 — Secure cross-cluster metrics (mTLS) — PASS

`multicluster-metrics-data-source` (`datalayer/source/metrics/multicluster.go`): default scheme **https with server verification ON** (the pod source defaults to http + skip-verify; the multicluster variant hardens the default for the cross-cluster boundary); parameters `caCertPath`, `clientCertPath` + `clientKeyPath` (mTLS client identity), `insecureSkipVerify`, `path` (default `/metrics`), `port` override, `interval` (scrape period, rounded to the `--refresh-metrics-interval` tick), `families`; 8 MiB response cap. Spoke side: EPP serves its metrics endpoint over mTLS (#1918, per epic). Metrics host can differ from the gateway host via `metricsAddress`/`metricsPort` labels (`datalayer/discovery/file/multicluster.go`).

Certificate rotation: upstream hot-reload is still in progress (#2045 / PR #2151, per epic) → **restart-based rotation runbook** at PoC time (A13); rotation causes a brief telemetry gap (risk R16).

## Item 6 — Failure semantics — PASS (code level; live validation assigned to P3/P4)

- **Metrics-path failure (T4.4):** a failed scrape returns an error and the extractor is not invoked (`datalayer/source/http/datasource.go` L259–264); attributes keep **last-known values** — no TTL invalidation in the write path (staleness is only surfaced via the observability logger's `stalenessThreshold`). → During a metrics outage the hub routes on stale data; T4.4 measures and documents this window instead of assuming failover.
- **Missing attributes:** unscored endpoints (queue scorer) — hub "eligibility" emerges from scorer/picker composition, not a hard health gate. Destination health signals available at hub = scrape success/failure + request outcomes.
- **Regional no-capacity:** admission maps queue outcomes to status codes — **503** when the pool has no endpoints, **429** when a queue-wait TTL expires while endpoints exist (`pkg/epp/requestcontrol/admission.go` L273–274) → basis for T4 pool-down and K1/K4 expectations.
- **EPP-down fail-open:** #3433's fail-open is a *standalone proxy* feature; with Envoy (AI) Gateway, ext-proc failure behavior is gateway-side (`failure_mode_allow` on the extension) → **P3/P4 verification item**: configure deliberately, and in T4.2 distinguish "requests still flowing via fail-open" from healthy EPP scheduling via decision evidence (item 10).
- **Zero eligible destinations at hub:** behavior (503 to client) to be demonstrated in T4.1.

## Item 7 — Flow control and saturation signals — PASS

Flow-control framework at v1.0.0: `bandselection`, `eviction`, `fairness`, `ordering`, `saturationdetector` (composite/concurrency/utilization variants), `usagelimits` (`pkg/epp/framework/plugins/flowcontrol/`). Queue outcomes include `RejectedNoEndpoints`, `EvictedTTL`; sheddable = priority < 0; per-request queue TTL header `x-llm-d-inference-ttl` (`pkg/epp/metadata/consts.go` L41) — the mechanism KEDA scale-from-zero relies on (P7). Saturation inputs for T3: `llm_d_epp_average_queue_size` (hub-visible) plus regional flow-control rejection/eviction metrics and 429/503 outcomes (item 6). Error requests are counted with status codes (`RecordRequestErrCounter`) and OTel span status.

## Item 8 — Gateway/provider compatibility — PASS (decision recorded)

llm-d @ release-1.0 pins **Gateway API CRDs v1.6.2** and **GAIE CRDs v1.6.2** (`guides/env.sh`) and documents these gateway providers (`docs/infrastructure/gateway/README.md`): Istio, **GKE Gateway**, Agentgateway, **Envoy AI Gateway**, NGINX Gateway Fabric. Plain Envoy Gateway is *not* listed as an llm-d provider; the Envoy-based documented path is Envoy **AI** Gateway.

**Decision (resolves A5, A6):** regional gateways and hub gateway = **Envoy AI Gateway `v0.7.0` on Envoy Gateway `v1.8.1`** — the llm-d v1.0.0 infra-matrix versions; EG v1.8.1 matches `vllm-gke` operational experience. The baseline ran AIGW v1.0.0; the PoC uses the llm-d-matrix v0.7.0 unless P3 finds an incompatibility (recorded as a finding either way). GKE Gateway (`docs/infrastructure/gateway/gke.md`) is the documented fallback provider.

Residuals: exact GKE version pinned at P2 (must run the v1.6.2 CRDs; GKE may pre-install some Gateway API CRDs — verify at P3, cf. upstream note "docs(gateway): qualify GKE's CRD auto-install").

## Item 9 — Simulator fidelity (A7) — PASS (doc level; live validation at P3)

`llm-d-inference-sim` v1.0.0 ([README @ v1.0.0](https://github.com/llm-d/llm-d-inference-sim/blob/v1.0.0/README.md)): fully OpenAI-compliant (HTTP + gRPC on one port); echo/random response modes; **TTFT with configurable jitter + inter-token latency + load-dependent latency**; **KV-cache simulation** (tracks simulated memory, publishes ZMQ block events); **failure injection** (`rate_limit`, `model_not_found` — useful for T4); LoRA metric simulation; exports "a subset of standard vLLM Prometheus metrics" (its `docs/metrics.md`).

Residual (P3 exit criterion): confirm the exported families cover what the regional `core-metrics-extractor` reads so the pool aggregates `llm_d_epp_average_queue_size` / `llm_d_epp_average_kv_cache_utilization` move under sim load; confirm sim instance identity is distinguishable per response/log line for T5. If insufficient, Environment A design is revised before any GPU spend.

## Item 10 — Correlation surface (no invented headers) — PASS

Real mechanisms at v1.0.0 (`pkg/epp/metadata/consts.go` L27–41; `pkg/epp/handlers/request.go` `generateMetadata`):

- `x-gateway-destination-endpoint` — the picked endpoint, attached by the EPP as ext-proc response metadata (used by Envoy to route).
- `x-gateway-destination-endpoint-scores` — every candidate's score, when the EPP runs with `--emit-endpoint-scores` (hub and regional EPPs will both run with it).
- `x-gateway-destination-endpoint-served` — metadata key for the endpoint that actually served.
- W3C trace propagation end-to-end (#2702); span names for the decision chain (`run_scheduler_profile`, `filter_endpoints`, `scoring`, `pick_endpoints` — `docs/operations/observability/tracing.md`); error counters with status codes.
- Header stripping (#3090) removes client-supplied *routing/screening* headers before forwarding; `x-session-token` is an EPP-consumed affinity header, not a stripped directive (item 4). Custom evidence headers are not assumed anywhere; correlation = trace IDs + the metadata keys above + timestamp-ordered logs.
- vLLM prefix-cache truth for T6: `vllm:prefix_cache_hits_total` / `vllm:prefix_cache_queries_total` (current names per llm-d observability docs @ release-1.0, verified against vLLM v0.30.0 at P5).

Residual (P3): verify how Envoy (AI) Gateway surfaces ext-proc metadata in access logs / response headers so run records can capture both decision levels per request.

---

## G1 summary

| # | Capability | Verdict |
|---|---|---|
| 1 | Multicluster work contained in v1.0.0 | PASS (git-verified) |
| 2 | Plugin names/attributes; alpha flag requirement | PASS |
| 3 | Deterministic + weighted + queue-based hub config; swap mechanism | PASS (mechanisms identified; profiles validated live at P4) |
| 4 | Cluster-scoped session + prefix affinity | PASS |
| 5 | mTLS cross-cluster metrics; cert rotation procedure | PASS (restart-based rotation until upstream #2045) |
| 6 | Failure semantics (stale metrics, 503/429, fail-open boundary) | PASS (code level; live validation P3/P4) |
| 7 | Flow control / saturation signals for T3 | PASS |
| 8 | Gateway compatibility; provider decision (Envoy AI Gateway v0.7.0 / EG v1.8.1) | PASS (GKE version pinned at P2) |
| 9 | Simulator fidelity | PASS (doc level; metric-fidelity check at P3) |
| 10 | Correlation surface; vLLM cache metric names | PASS (metadata exposure verified at P3) |

**Gate G1 recommendation: PASS** — proceed to P2 preparation. Fallback path (PLAN.md §5) not needed. Residual live-verification items are assigned to P3/P4 exits and listed above; none blocks deployment planning.
