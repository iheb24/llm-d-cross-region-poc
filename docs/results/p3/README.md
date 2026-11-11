# P3 evidence — Environment A regional spokes on simulators (2026-11-11)

## Deployed per region (versions per versions.lock)

- Gateway API CRDs v1.6.2 + GAIE CRDs v1.6.2 (neither pre-installed by GKE — checked).
- Envoy Gateway v1.8.1 + Envoy AI Gateway v0.7.0 (`k8s/install-spoke.sh`).
- Regional Gateway `llm-d-inference-gateway` (class `envoy-ai-gateway`), **PROGRAMMED=True**, bound to reserved IPs via GatewayClass→EnvoyProxy Service patch (`k8s/region-*/envoyproxy.yaml`).
- 2 × `llm-d-inference-sim:v1.0.0` (Deployment `llmd-sim`, model name `llmd-poc-sim`).
- Regional EPP `ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0` (chart `llm-d-router-gateway:v1.0.0`, release `llmd-router`), `--emit-endpoint-scores`, `--allow-experimental-plugins` (session-affinity-filter is alpha), InferencePool over `app=llmd-sim`, HTTPRoute → regional Gateway.
- GMP enabled per cluster; `ClusterPodMonitoring` for EPP (:9090) and sims (:8000).

## Findings that changed the approach

1. **Gateway `spec.addresses` does not work on GKE**: Envoy Gateway maps it to Service `externalIPs`, which GKE admission denies ("Use of external IPs is denied by admission control"). Solution: `EnvoyProxy` `envoyService.patch` setting `spec.loadBalancerIP`, attached via `GatewayClass.spec.parametersRef`. Gateway then reports the reserved IP with `ipMode: VIP`, `PROGRAMMED=True`.
2. **helm OCI pulls failed** in this shell (`docker-credential-desktop` not on PATH): fixed by pointing helm at an empty `DOCKER_CONFIG` (public charts need no auth). Baked into `install-spoke.sh`.
3. **Chart default EPP resources (cpu 8 / mem 8Gi)** don't fit the `e2-standard-4` system node → PoC-sized to 500m/1Gi request in `router-values.yaml`.
4. **EPP `/metrics` requires bearer auth by default** (401); PoC runs it unauthenticated on the ClusterIP port (`monitoring.prometheus.auth.enabled: false`). The hub's cross-cluster scrape (B3) gets a secured exposure at P4 — deliberately not solved yet.

## Validation results (P3 exit criteria)

| Check | EU | US |
|---|---|---|
| Direct-spoke request via regional gateway | HTTP 200 (`34.34.96.149`) | HTTP 200 (`34.70.139.142`) |
| Serving-pod identity in response headers | `x-inference-pod: llmd-sim-…` present | same |
| EPP selects BOTH sims (distribution) | 18/6 over 24 requests | 8/4 over 12 requests |
| Session affinity (`x-session-token` returned & honored) | 6/6 pinned to one pod | (mechanism identical) |
| `llm_d_epp_average_queue_size` exported | yes (`{name="llmd-router"}`) | yes |
| `llm_d_epp_average_kv_cache_utilization` exported | yes | yes |
| `llm_d_epp_ready_endpoints` | 2 | 2 |
| Version proof | `llm_d_epp_info{build_ref="v1.0.0", commit="b9393d1a…"}` | same chart/image |

**A7 live check (G1 item 9 residual): PASS** — regional EPP exports exactly the pool aggregates the hub's `multicluster-metrics-extractor` reads by default, with per-endpoint sim telemetry flowing (`llm_d_epp_per_endpoint_queue_size{model_server_endpoint="llmd-sim-…-rank-0"}`).

**Correlation surface (G1 item 10 residual): PASS at regional level** — v1.0.0 emits `x-inference-pod`, `x-inference-namespace`, `x-inference-port` response headers plus the `x-session-token` affinity header; no invented headers needed. Hub-level metadata capture is verified at P4.

## Remaining P3→P4 items

- GMP ingestion spot-check (Metrics Explorer shows `llm_d_epp_average_queue_size`) — P4 entry check.
- Secured cross-cluster exposure of the regional EPP metrics endpoint (B3: TLS + auth design, then hub scrape config).
- EU sim distribution skew (18/6) — expected with weighted-random picking at small N; not a defect.

## Cost posture

Unchanged: 2 × `e2-standard-4` + 3 static IPs. GMP ingestion is small (2 targets/cluster @15s). No GPUs.
