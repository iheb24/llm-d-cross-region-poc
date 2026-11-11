# llm-d Cross-Region PoC — Implementation Plan

| | |
|---|---|
| Status | Planning baseline — no infrastructure deployed |
| Date | 2026-11-11 |
| Repository | `llm-d-cross-region-poc` (new, independent; local-only until a remote is explicitly approved) |
| Upstream baseline | `vllm-gke` (separate project, preserved as-is — see §2) |
| Scope | Planning document. All `terraform apply`, `kubectl apply`, Helm installs, and any destructive command require explicit user approval at the phase where they occur. |

---

## 1. Executive summary and PoC success statement

This PoC evaluates **llm-d as a hierarchical inference-routing layer across two GKE clusters in different regions** (initially Europe and the United States). A hub-level llm-d Endpoint Picker (EPP) chooses a regional destination; a regional EPP then chooses a local inference endpoint:

```
                              ┌──────────────────────────┐
Client ─────────────────────► │ Hub llm-d EPP            │
                              │ Selects EU or US gateway │
                              └─────────────┬────────────┘
                                            │
                       ┌────────────────────┴────────────────────┐
                       ▼                                         ▼
             EU regional gateway                       US regional gateway
                       │                                         │
                EU regional EPP                             US regional EPP
                Selects local endpoint                      Selects local endpoint
                       │                                         │
                 EU vLLM pool                                US vLLM pool
```

The PoC is an **evaluation, not a commitment to adopt llm-d**. It optimizes for clear evidence, controlled scope, reproducibility, and easy teardown. It proceeds in small, independently validated phases: architecture validation (source-only) → functional routing on simulators → real-GPU validation → overload/failure/affinity → optional autoscaling.

**The PoC succeeds when it demonstrates, with reproducible evidence:**

- deliberate EU/US regional selection;
- preferred-region overflow based on measured pressure;
- predictable behavior during independently injected regional failures;
- a provable hub-region and regional-endpoint decision chain (two-level routing);
- measured latency overhead for direct-spoke, local-via-hub, and cross-region-via-hub paths;
- session/prefix routing behavior and **actual vLLM prefix-cache reuse confirmed by serving metrics** (not inferred from TTFT alone);
- clearly documented limitations and unsupported claims.

Optional autoscaling (KEDA) success is reported separately and must not obscure the core routing results.

**Non-goals** (fixed for this PoC): cross-region prefill/decode disaggregation; cross-region KV-cache transfer; direct scheduling onto remote vLLM Pod IPs; treating GKE Multi Cluster Services / selector-less Services / manual EndpointSlices as proof of llm-d multi-cluster routing; integration into `vllm-gke`; semantic model/tier routing in the request path; RAG/CPU-SLM/Chat-UI/showcase migration; hub HA; client-geography detection; zero failed requests during failure injection; retrying partially streamed responses; data-residency guarantees.

---

## 2. Source-repository findings and reusable assets (gate G0 record)

Inspection performed 2026-11-11. The local checkout is the source of truth for reusable project details.

| Fact | Value |
|---|---|
| Path | `/Users/ihebbesbes/workspace/vllm-gke` |
| Branch | `main` (clean working tree, in sync with `origin/main`) |
| HEAD commit | `eddef67eea47689cf6efc493fdca5bb9c58154c3` (2026-10-29, "fix(showcases): merge review findings…") |
| Remote | `https://github.com/iheb24/vllm-gke.git` |
| License | MIT, © 2026 Iheb Besbes — own code; carry the LICENSE notice into adapted files; no external attribution blocker |
| Uncommitted changes | None |

### Baseline architecture (as inspected)

Single-zonal GKE cluster in `us-central1-a`: always-on `e2-standard-4` system pool; Spot NVIDIA L4 GPU pool (`g2-standard-8`, autoscale 0–1); `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` on vLLM; Qwen3-4B (llama.cpp) CPU tier; Envoy Gateway v1.8.1 + Envoy AI Gateway v1.0.0; vLLM Semantic Router (ExtProc, chart `0.0.0-latest`); KEDA + KEDA HTTP Add-on (both unpinned in `k8s/install_keda.sh`); `ClusterIP` vLLM Service; 50 Gi `standard-rwo` PVC.

Routing path today: Client → Envoy Gateway / AI Gateway → Semantic Router ExtProc → CPU model **or** KEDA HTTP interceptor → one vLLM GPU endpoint.

### Confirmed baseline limitations (with evidence)

| Limitation | Evidence |
|---|---|
| Region hardcoded to `us-central1` | `infra/environments/dev/main.tf` (module call sites); zone default `us-central1-a` in `infra/modules/vllm-cluster/variables.tf` |
| CIDRs hardcoded | `infra/modules/network/main.tf`: subnet `10.0.0.0/20`, pods `10.4.0.0/14`, services `10.8.0.0/20`; `infra/modules/vllm-cluster/main.tf`: master `172.16.0.0/28` |
| Unpinned model-server image | `k8s/vllm-chart/values.yaml`: `vllm/vllm-openai:latest` |
| Unpinned KEDA install | `k8s/install_keda.sh` (no `--version`) |
| One vLLM replica max | GPU pool autoscale 0–1; chart `scaling.maxReplicas: 1` — cannot prove pod-level selection |
| Semantic Router answers "which model/tier?", not "which region/pod?" | `k8s/semantic-router/` |
| KEDA HTTP Add-on ≠ llm-d scale-from-zero mechanism | llm-d documents its own KEDA+EPP-metrics path (§5, §8) |

### Provenance: copied / adapted / new

| Component | Disposition | Notes |
|---|---|---|
| `infra/modules/network` | **Adapt** | Parameterize region and all CIDRs; one VPC per PoC (new VPC, existing `vllm-vpc` untouched) |
| `infra/modules/vllm-cluster` | **Adapt** | Parameterize zone, cluster name, machine types, accelerator, node-count/replica limits; strip `rag.tf`; keep Workload Identity, private nodes, authorized networks |
| `k8s/vllm-chart` deployment/PVC/SA templates | **Adapt** | Pin image; add EPP/InferencePool integration; keep regional 50 Gi PVC pattern (model storage stays regional — no transatlantic shared storage) |
| `k8s/rag/observability` patterns (Prometheus v3.5.0, Grafana 11.6.0, PodMonitoring) | **Reference** | Starting point for per-cluster metrics of EPP/vLLM |
| `docs/cost-checkpoint.md` | **Reference** | Cost model extended for 2 clusters + egress |
| Semantic Router, AI Gateway config, CPU SLM, Chat UI, Cline setup, RAG, showcases, KEDA HTTP Add-on | **Not carried** | Explicitly outside the PoC critical path |
| Hub EPP config, multicluster discovery/metrics wiring, simulator deployments, test/evidence tooling | **New** | Built in this repo against pinned llm-d v1.0.0 (§5) |

---

## 3. Assumptions, defaults, and unresolved decisions

Nothing below is treated as fact until its resolution gate closes it. IDs are referenced from phases.

| ID | Assumption / default | Status | Resolved by |
|---|---|---|---|
| A1 | Repo lives at `/Users/ihebbesbes/workspace/llm-d-cross-region-poc`, local git only; pushing a remote needs separate approval | Decided | — |
| A2 | PoC deploys into the **same GCP project** as `vllm-gke` but a **new dedicated VPC** (`llmd-poc-vpc`); existing stack untouched | **Resolved (user, 2026-11-11)** | — |
| A3 | US cluster in `us-central1-a`; EU cluster in `europe-west4-a`; L4 quota in both regions confirmed by user 2026-11-11; Spot capacity at allocation time remains a runtime risk (R14) | **Resolved (user, 2026-11-11)** | — |
| A4 | Hub colocated in the **US** cluster (single hub, no HA — documented limitation) | Decided (context §6) | — |
| A5 | Gateway provider: **Envoy AI Gateway v0.7.0 on Envoy Gateway v1.8.1** (llm-d v1.0.0 matrix versions; plain Envoy Gateway is not a documented llm-d provider; GKE Gateway = documented fallback) | **Resolved (G1 item 8)** | version-evidence.md §8 |
| A6 | Envoy AI Gateway **is** the documented Envoy-based gateway provider and is in the request path as the GAIE gateway; no semantic routing added | **Resolved (G1 item 8)** | version-evidence.md §8 |
| A7 | `llm-d-inference-sim` telemetry (queue/KV metrics, configurable latency, failure injection) is sufficient for hub scorers and T-tests | Doc-level pass (G1 item 9); live metric-fidelity check remains | P3 exit |
| A8 | Weighted regional routing: `endpoint-attribute-weight-scorer` (region weights) + `weighted-random-picker` (score-proportional sampling) | **Resolved (G1 item 3)** | version-evidence.md §3 |
| A9 | Deterministic region forcing via **hub EPPConfig swap** (label filter on discovery-file region labels, applied by `helm upgrade`); client-supplied routing headers confirmed stripped in v1.0.0 | **Resolved (G1 item 3)** | version-evidence.md §3 |
| A10 | One EPP replica per level; EPP HA/active-active (router #3133, #3431) out of scope | Decided | — |
| A11 | Model stays `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` on one L4 per region, pinned to an immutable Hugging Face revision; identical tokenizer/chat-template/quantization/context/prefix-cache settings in both regions | Open | P1 (record revision SHA in `versions.lock`) |
| A12 | Cross-cluster addressing: reserved static IPs + DNS names for regional gateways (Cloud DNS or equivalent) | Open | P2 |
| A13 | TLS: hub→spoke-gateway HTTPS and hub→spoke-EPP mTLS metrics; issuer (cert-manager vs Google-managed) undecided; cert rotation requires EPP restart until upstream hot-reload (router #2045/#2151) ships | Open | G1 item 5 / P2 |
| A14 | Metrics collection: per-cluster Prometheus (GKE Managed Prometheus preferred if it can scrape the EPP metrics endpoint with TLS) | Open | P3 |
| A15 | T9 clients: one GCE VM (or equivalent) per region, EU + US, as controlled client locations | Open | P6 |
| A16 | Always-warm means: GPU node present and vLLM `replicas: 1` during test windows; GPU pools scale to 0 outside test windows | Decided | — |

---

## 4. Architecture and trust/network boundaries

### Components per location

- **US cluster** (`us-central1-a`, proposed): system pool + GPU pool; regional Envoy Gateway; regional EPP; vLLM pool (Env B) or 2 simulators (Env A); **hub EPP**; per-cluster Prometheus.
- **EU cluster** (`europe-west4-a`, proposed): system pool + GPU pool; regional Envoy Gateway; regional EPP; vLLM pool (Env B) or 2 simulators (Env A); per-cluster Prometheus.

The hub routes to a **regional gateway**, never to a vLLM Pod directly. Each spoke gateway is independently reachable (direct-spoke access preserved for latency baselines). Regional model servers, cache state, telemetry, and scaling remain under regional ownership.

### Network plan (proposed; validated at P2)

Non-overlapping across both PoC clusters **and** the existing `vllm-vpc` (`10.0.0.0/20`, `10.4.0.0/14`, `10.8.0.0/20`, `172.16.0.0/28`):

| Range | EU cluster | US cluster |
|---|---|---|
| Subnet (nodes) | `10.10.0.0/20` | `10.20.0.0/20` |
| Pods (secondary) | `10.12.0.0/14` | `10.24.0.0/14` |
| Services (secondary) | `10.18.0.0/20` | `10.28.0.0/20` |
| Control plane | `172.16.0.16/28` | `172.16.0.32/28` |

Both clusters: zonal (free management tier), private nodes, public endpoint restricted by authorized networks, Workload Identity, Cloud NAT.

### Trust boundaries

| # | Boundary | Policy |
|---|---|---|
| B1 | Client → hub gateway | HTTPS, auth token (baseline pattern) or mTLS — decided P2; hub gateway exposed via load balancer |
| B2 | Hub → regional gateway (data plane, cross-region) | HTTPS; **prompt data crosses jurisdictions — no data-residency claim**; regional gateways accept hub and direct-baseline traffic (distinguishable for evidence) |
| B3 | Hub → regional EPP `/metrics` (telemetry plane, cross-region) | mTLS; server verification on by default upstream (router #2232); certificates per A13 |
| B4 | Regional internals (gateway↔EPP ext-proc, EPP↔pods, Prometheus scrapes) | Cluster-local; Workload Identity |
| B5 | Operator → clusters | `gcloud`/terraform from authorized IPs only; no broad firewall openings |

Failure of B3 (metrics) while B2 (requests) stays healthy is an explicit T4 sub-test — the hub must not silently keep routing on stale data without that being measured and documented.

---

## 5. Selected versions and the G1 version-validation task

### Pinned candidate set

Research date 2026-11-11. Anchor release: **llm-d v1.0.0** (released 2026-10-19, [release notes](https://github.com/llm-d/llm-d/releases/tag/v1.0.0)), which aligns all core component versions.

| Component | Pinned version | Source |
|---|---|---|
| llm-d router EPP (image + Helm chart) | `v1.0.0` | llm-d v1.0.0 component table |
| llm-d inference simulator | `v1.0.0` (`llm-d-inference-sim`) | llm-d v1.0.0 component table |
| llm-d autoscaling (chart; P7 only) | `v1.0.0` (`llm-d-autoscaling`) | llm-d v1.0.0 component table |
| vLLM | `v0.30.0` (`docker.io/vllm/vllm-openai:v0.30.0`) | llm-d v1.0.0 model-server table |
| Gateway API Inference Extension (GAIE) CRDs | `v1.6.2` (API group `inference.networking.k8s.io`) | llm-d v1.0.0 infra table |
| Gateway API CRDs | per llm-d v1.0.0 infra table (`v1.6.2` alignment; confirm exact CRD bundle in G1) | llm-d v1.0.0 infra table |
| Envoy Gateway | `v1.8.1` | llm-d v1.0.0 infra table; also proven in `vllm-gke` |
| inference-perf (load generator) | `v0.7.0` | llm-d v1.0.0 component table |
| Model | `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` @ immutable HF commit SHA | recorded in `versions.lock` at P1 |
| KEDA (P7 only) | latest stable at P7 time — pin exact chart version then | replaces unpinned baseline install |
| Terraform + google provider | terraform `>= 1.0` pinned via `.terraform.lock.hcl`; provider version pinned per env | baseline locked `7.41.0` |
| GKE control-plane version | specific version recorded at P2 (GAIE compat checked in G1 item 8) | — |

No `latest` tags anywhere. `versions.lock` (created at P1) is the single source of truth; any change reopens G1 for the delta.

### Why llm-d v1.0.0 is the candidate (research summary)

- The hub-and-spoke design ("hub mode": EPP candidates generalized from pods to destinations; cross-cluster signal = spoke EPP pool-aggregate metrics) is tracked in epic [llm-d-router#1907](https://github.com/llm-d/llm-d-router/issues/1907). Marked shipped: endpoint identity (#2147), metrics-scrape TLS options (#1858), EPP metrics over mTLS (#1918), multicluster scheduling plugin family (#2244).
- The plugin family landed in PR [llm-d-router#2232](https://github.com/llm-d/llm-d-router/pull/2232), merged 2026-08-04 (merge commit `38e3412cdcb55ed78560af1ed921bb97f51f3f21`) — i.e., before the v1.0.0 cut. It provides: `multicluster-file-discovery` (accepts **RFC-1123 hostnames or IPs** → regional gateways can be DNS names), `multicluster-metrics-data-source` / `multicluster-metrics-extractor` (scrape spoke pool aggregates `llm_d_epp_average_kv_cache_utilization`, `llm_d_epp_average_queue_size`; TLS-verified by default), `multicluster-queue-scorer`, `multicluster-kv-cache-utilization-scorer`, `multicluster-session-affinity-filter`, `multicluster-prefix-cache-scorer`, `multicluster-approx-prefix-cache-producer`. Config example: `pkg/epp/framework/plugins/README.md` at the release tag.
- v1.0.0 properties that shape test design: W3C trace propagation in EPP (#2702) and Prometheus trace exemplars → correlation backbone; **client-supplied routing headers stripped** (#3090) → T1 forcing must be hub config (A9); **fail-open routing when the EPP is unreachable** (#3433) → T4 must distinguish fail-open from healthy scheduling; `EPPConfig`/`InferenceObjective` graduate to `llm-d.ai/v1`.
- KEDA + EPP queue metrics with scale-from-zero is a documented guide (queue-TTL for scale-from-zero, #2794; inflight signal default, #2815).

### G1 — version and architecture validation task (source-only, no deployment)

Every item must be verified **from the pinned tag's own source/docs**, with evidence (permalinks + config excerpts) captured in `docs/version-evidence.md`:

1. **Containment:** clone `llm-d/llm-d-router`; `git tag --contains 38e3412cdcb55ed78560af1ed921bb97f51f3f21` includes `v1.0.0`; record output.
2. **Plugin presence/registration:** the eight `multicluster-*` plugins exist and are registered at tag `v1.0.0`; exact plugin type names and exact attribute keys (epic text mentions `llm-d.ai/pool-*`, PR body mentions `llm-d.ai/multicluster-*` — record the release-truth spelling).
3. **Hub config surface (EPPConfig `llm-d.ai/v1`):** working examples for (a) deterministic destination selection (for T1, per A9), (b) weighted scoring across destinations (for T2, per A8), (c) load/queue-based multi-cluster scoring with a configurable saturation threshold (for T3), including how a profile/config swap is performed in a running hub.
4. **Cluster-scoped affinity:** `multicluster-session-affinity-filter` and `multicluster-prefix-cache-scorer` config: how session identity is supplied by the client, how long affinity state persists, and how load overrides affinity (for T6–T8).
5. **Secure cross-cluster metrics:** exact mTLS scrape configuration (#1858/#1918), CA/cert provisioning, and rotation behavior; status of hot-reload (#2045/#2151) at pin time → rotation runbook step (A13).
6. **Failure semantics:** hub destination health/eligibility behavior on scrape failure vs. request failure; timeouts/refresh intervals; fail-open behavior (#3433) and its config; what the hub does with zero eligible destinations (for T4).
7. **Flow control/saturation signals:** which EPP/queue metrics exist for defining the T3 saturation threshold, and how regional EPP queueing behaves under overload (status codes, shedding).
8. **Gateway compatibility:** GAIE `v1.6.2` CRDs vs. the GKE version to be pinned; Envoy Gateway `v1.8.1` + GAIE `v1.6.2` support; confirm whether AI Gateway is needed at all (A5, A6).
9. **Simulator fidelity (A7):** `llm-d-inference-sim` v1.0.0 — which metrics it exports (queue depth, KV-cache utilization, TTFT/ITL simulation), OpenAI API coverage, identifiability of the serving instance in responses/logs.
10. **Correlation surface:** what identifies hub and regional decisions per request (trace context propagation, EPP decision logs/metrics, any response headers that legitimately exist in v1.0.0 — do not invent any); current vLLM prefix-cache metric names for v0.30.0 (metric names changed across releases — verify against the pinned image).

**G1 exit:** `docs/version-evidence.md` answers all 10 items with version-tagged citations; `versions.lock` frozen; draft hub and regional EPPConfig YAML reviewed and committed (not applied). **Fallback:** if any required capability is missing at v1.0.0, evaluate the newest router tag containing it, or a dated `main` commit, document the trade-off, and re-run G1. Do not proceed to P2 on assumptions.

---

## 6. Phase plan

Rules for all phases:

- One phase active at a time; a phase starts only after the previous phase's exit criteria are met and its evidence is archived.
- Every cloud-changing or destructive action (`terraform apply/destroy`, `kubectl apply/delete`, `helm install/uninstall`) requires explicit user approval at execution time.
- Every test run records: routing-policy version, component versions (from `versions.lock`), model revision, cluster state, ready-endpoint counts, and failure-injection timestamps (§9).
- Each phase ends with its own rollback path and leaves a documented teardown route, independent of later phases.
- Gates: **G0** end of P0, **G1** end of P1, **G2** end of P4, **G3** end of P5, **G4** end of P6, **G5** end of P7 (optional).

### P0 — Repository and source-baseline record (G0)

- **Depends on:** approved PLAN.md (this document).
- **Entry:** PLAN.md committed.
- **Actions:** record §2 facts into `docs/source-baseline.md` (path/commit/license/provenance); create the skeleton directories of §12 **without** infra, manifests, or scripts; note any `vllm-gke` drift since 2026-11-11 (re-check commit; this PoC never modifies `vllm-gke`).
- **Exit (G0):** source state, goals, non-goals, regions, and hardware strategy confirmed by the user; provenance table complete.
- **Evidence:** committed `docs/source-baseline.md`.
- **Rollback:** delete the files. **Teardown:** n/a (no cloud resources).

### P1 — Version and architecture validation (G1, source-only)

- **Depends on:** P0. **Creates no cloud resources.**
- **Entry:** G0 passed.
- **Actions:** execute the G1 checklist (§5) — clone llm-d repos read-only, verify containment, extract config examples from tag `v1.0.0`; write `docs/version-evidence.md`; freeze `versions.lock` (incl. model HF revision SHA, KEDA version deferred-but-bounded, GKE version target); draft (commit, do not apply) hub EPPConfig, regional EPPConfig, and the multicluster discovery file; decide A5/A6/A8/A9/A13.
- **Exit (G1):** all 10 G1 items answered with version-tagged evidence, or descoped with an explicit limitation note; configs reviewed.
- **Evidence:** `docs/version-evidence.md`, `versions.lock`, draft configs.
- **Rollback:** select fallback version, re-run G1 (see §5). **Teardown:** delete local clones.

### P2 — Regional cluster skeletons

- **Depends on:** P1. **First phase that creates cloud resources.**
- **Entry:** G1 passed; A2 confirmed; A3 resolved by quota/capacity check (`gcloud compute regions describe`, L4 GPU quota + Spot availability in both zones); explicit approval to apply terraform.
- **Actions:** adapt terraform modules (parameterize region/zone/cluster name/machine types/accelerator/node and replica limits/CIDRs per §12); create the new VPC, EU cluster, and US cluster (system pools only — no GPU pools yet); reserve static IPs and DNS names for both regional gateways and the hub gateway (A12); configure authorized networks; verify CIDR non-overlap (against plan and existing `vllm-vpc`) and control-plane reachability.
- **Exit:** both clusters healthy; `kubectl` contexts work; addresses/DNS resolve; terraform outputs committed to `docs/results/p2/`.
- **Evidence:** terraform plan/apply logs, outputs, CIDR table, quota-check output.
- **Rollback:** `terraform destroy` (with approval). **Teardown:** same; idle cost ≈ 2 × `e2-standard-4` + free zonal control planes.

### P3 — Environment A: regional llm-d spokes on simulators

- **Depends on:** P2.
- **Entry:** P2 exit; approval for in-cluster installs.
- **Actions (per region):** install GAIE CRDs `v1.6.2`; Envoy Gateway `v1.8.1`; regional Gateway + TLS + DNS (independently reachable); regional EPP `v1.0.0` via the pinned chart; `InferencePool` with **2 `llm-d-inference-sim:v1.0.0` endpoints**; expose the EPP metrics endpoint with the mTLS setup the hub will use (B3); per-cluster Prometheus scrape (A14). Validate: direct-spoke requests in each region; over repeated requests the regional EPP selects **both** simulators (pod-level selection evidence); metrics endpoint scrapable using hub credentials; simulator identity distinguishable per response (A7).
- **Exit:** single-level (regional) llm-d routing proven in both regions; A7 resolved; if sim telemetry is insufficient, Environment A design is revised before any GPU spend.
- **Evidence:** request logs with endpoint identity, EPP decision evidence, scrape configs and samples in `docs/results/p3/`.
- **Rollback/teardown:** `helm uninstall` of router/gateway components + CRD removal; clusters remain.

### P4 — Environment A: hub routing (G2)

- **Depends on:** P3.
- **Entry:** P3 exit; G1-reviewed hub config available.
- **Actions:** deploy hub EPP `v1.0.0` in the US cluster; `multicluster-file-discovery` listing EU/US **gateway hostnames**; `multicluster-metrics-data-source`/`-extractor` scraping both spoke EPPs over mTLS; multicluster scheduling profiles per G1 item 3. Run **T1** (deterministic EU-forced, then US-forced), **T2** (weighted distribution with predefined statistical tolerance), **T5** (two-level proof + negative control bypassing the regional EPP), and **T4-sim** (failure injection in the functional environment: gateway down; pool down with gateway healthy; hub→spoke path interrupted; metrics path interrupted with data path intact; recovery).
- **Exit (G2):** T1/T2/T5 pass with complete request correlation; T4-sim timings recorded (injection→detection, in-flight failures, requests sent to failed destination, time to surviving-region-only, recovery/flapping, partial-SSE behavior). Real-GPU deployment is blocked until G2 passes.
- **Evidence:** `docs/results/p4/<run-id>/` JSONL + analysis notes per §9.
- **Rollback:** scale hub deployment to 0; revert discovery/config to last passing commit. **Teardown:** hub `helm uninstall`; spokes remain for re-runs.

### P5 — Environment B: real inference (G3)

- **Depends on:** P4. **First GPU spend.**
- **Entry:** G2 passed; GPU quota re-verified; explicit approval for GPU costs; model revision frozen (A11).
- **Actions (per region):** add GPU node pool (Spot `g2-standard-8`, 1×L4, autoscale 0–1; during test windows hold 1 node, `replicas: 1` — always-warm per A16); regional 50 Gi PVC; vLLM `v0.30.0` serving the pinned model with **identical** tokenizer, chat template, quantization, context, and prefix-cache settings in both regions; point the regional InferencePool at the real endpoint (keep simulators available for controls). Tests: direct-spoke baselines (latency/streaming per region); first half of **T9**; **T6** core (fresh long prefix → cold TTFT + cache counters; reuse → verify affinity decision **and** vLLM prefix-cache counter increase; force to other region → cold; repeat → warm), with fresh prefixes or controlled cache resets between trials; via-hub smoke in both directions.
- **Exit (G3):** real TTFT/streaming evidenced on direct and via-hub paths; T6 pass criteria met with serving-metric confirmation (not TTFT inference alone).
- **Evidence:** `docs/results/p5/` incl. vLLM cache counters, TTFT/TPOT distributions, route correlation.
- **Rollback:** scale GPU pools to 0; point pools back at simulators. **Teardown:** delete vLLM releases, PVCs, GPU node pools (keeps clusters).

### P6 — Overload, failure, and affinity on the real stack (G4)

- **Depends on:** P5.
- **Entry:** G3 passed; T9 clients provisioned (A15); approval for sustained load generation.
- **Actions:** **T3** preferred-region overflow (EU preferred: baseline → controlled EU load with `inference-perf v0.7.0` until the G1-defined saturation threshold → US overflow → stop → recovery; repeat US-preferred to expose hub home-region bias); **T4** full failure matrix on the real stack (five sub-tests, timings as in P4); **T7** multi-turn conversation affinity (turns retain region/endpoint while healthy; reusable cached prefix tokens; forced migration cold first turn; return tested without assuming residency; induced-overload override recorded); **T8** cache-vs-load (warm-but-loaded vs cold-but-idle endpoint; verdict consistent with configured scoring policy — an intentional load-aware override is not a cache-routing failure); **T9** full latency matrix (direct-spoke / via-hub-near / via-hub-far × EU and US clients; hub+regional scheduling time, queueing, TTFT, TPOT, total, throughput, errors, p50/p95 — p99 only with adequate samples; cold- and warm-prefix reported separately).
- **Exit (G4):** all evidence archived; limitations written (e.g., one endpoint/region ⇒ regional pod-level selection proven only in Env A; optional second real endpoint in one region for a GPU-backed two-level cache test is a documented extension, not part of core success).
- **Evidence:** `docs/results/p6/` per test, with saturation-threshold definition and load-generator configs.
- **Rollback:** stop load generators; restore baseline policy. **Teardown:** as P5, plus client VMs.

### P7 — Optional: llm-d-native KEDA autoscaling (G5)

- **Depends on:** P6. **Optional; starts only on explicit go-ahead. Core PoC success does not depend on it.**
- **Entry:** G4 complete; KEDA chart version pinned and recorded in `versions.lock`.
- **Actions:** install pinned KEDA + llm-d autoscaling chart `v1.0.0` following the pinned version's documented KEDA+EPP-metrics path (not the old KEDA HTTP Add-on); configure scale-from-zero (EPP queue TTL per upstream guidance); validate exact flow-control behavior on a sleeping pool before designing around it. Run **K1** (force traffic to a cold region; prove regional EPP queueing + KEDA activation). Then a **feasibility check**: can the hub observe regional warm/cold/waking state with the pinned version (readiness signals, metrics)? Only if demonstrated, run **K2** (warm-first with one cold region), **K3** (cold activation only after warm overflow/failure), **K4** (both regions cold).
- **Exit (G5):** K1 evidenced; K2–K4 each reported as *demonstrated*, *demonstrated-with-custom-policy*, or *not supported by the pinned version* — never claimed as inherited KEDA features.
- **Evidence:** `docs/results/p7/`, incl. activation latency and request outcomes during wake.
- **Rollback:** restore `replicas: 1`; remove ScaledObjects/KEDA. **Teardown:** uninstall KEDA + autoscaling chart.

### P8 — Evidence consolidation and teardown

- **Depends on:** P6 (and P7 if executed).
- **Entry:** G4 (+G5) evidence archived.
- **Actions:** write the final report against §1 success criteria (claims vs. evidence vs. unsupported items); record actual costs and egress vs. the `vllm-gke` cost model; archive all run records; execute full teardown (`terraform destroy` after helm cleanup) with a verification checklist (console + billing confirm zero remaining PoC resources); repo final state = docs, configs, results only.
- **Exit:** report committed; teardown verified.
- **Evidence:** `docs/final-report.md`, teardown verification output.
- **Rollback:** n/a. **Teardown:** is the phase.

---

## 7. Test matrix (T1–T9)

Common rules: no performance-improvement targets before baselines exist; warm/cold always reported separately; every request reconstructable per §9; "sim" = `llm-d-inference-sim`, "real" = vLLM+L4.

| Test | Env / Phase | Procedure (skeleton) | Pass evidence |
|---|---|---|---|
| **T1** Deterministic regional selection | A / P4; smoke re-run B / P5 | Apply EU-forced hub config, send identical requests, then US-forced. Forcing = hub config/policy (A9), never request fields | 100% of successful requests reach the expected regional gateway, full correlation per request |
| **T2** Weighted regional routing | A / P4; small smoke B / P6 | Configure EU/US weights; generate enough sim requests for a distribution check; predefined statistical tolerance (e.g., chi-square at N ≥ 400, tolerance fixed before the run) | Observed allocation within tolerance of configured weights |
| **T3** Preferred region + overflow | B / P6 (mechanism rehearsed in A / P4) | EU preferred, US idle: baseline → ramp EU load (inference-perf) past the G1-defined saturation threshold → observe US overflow → stop load → recovery. Repeat US-preferred (home-region bias check) | No unexplained US traffic before threshold; US receives traffic after detection; queueing/TTFT/errors recorded; no persistent oscillation after recovery |
| **T4** Regional failure handling | A / P4 (sim), B / P6 (real) | Five independent injections: (1) regional gateway down; (2) inference pool down, gateway healthy; (3) hub→spoke data path interrupted; (4) metrics path interrupted, data path intact; (5) recovery | Per sub-test: injection→hub-detection time; in-flight failures; requests sent to failed destination during detection; time to surviving-region-only routing; recovery time and route flapping; partial-SSE behavior. Zero failures is **not** required; partial streams are not auto-replayed |
| **T5** Two-level routing | A / P4 | Distinguishable hub vs. regional policies; ≥2 endpoints/region; negative control bypassing the regional EPP | Every request record contains hub-selected region **and** independently selected regional endpoint; negative control shows the evidence disappears without the regional EPP |
| **T6** Exact prefix-cache behavior | B / P5 | Several-thousand-token fixed prefix + short varying suffixes: cold send → record region/endpoint/TTFT/counters; reuse → verify affinity decision + counter increase; force other region → cold; repeat → warm. Fresh prefixes or controlled resets between trials | vLLM prefix-cache counters increase on reuse; complete route evidence; warm/cold TTFT compared at equivalent input lengths and controlled output lengths |
| **T7** Multi-turn affinity | B / P6 | Several turns with exact growing history; then forced migration; then return | Turns retain region/endpoint while healthy; later turns show reusable cached prefix tokens; migration turn is cold; return does not assume residency; induced-overload affinity override recorded as policy-consistent |
| **T8** Cache-vs-load policy | A / P4 (2 sims); spot-check B / P6 | One endpoint warm for prefix P and loaded; one cold and idle; send P-suffixed requests | Selected endpoint consistent with the configured scoring policy; intentional load-aware overrides not labeled as cache-routing failures |
| **T9** Latency comparison | B / P5–P6 | EU and US clients (A15) × three paths: direct regional gateway; hub→near gateway; hub→far gateway | Per path: hub scheduling time, regional scheduling time, queueing, TTFT, TPOT, total, throughput, errors, p50/p95 (p99 only with adequate samples); cold vs. warm separated |

A successful HTTP response alone is never accepted as evidence of the intended route.

---

## 8. KEDA / regional-capacity phase (K1–K4, P7)

Responsibilities stay separated: hub chooses a region; regional EPP queues/admits and picks endpoints; KEDA scales the regional model Deployment from EPP-derived metrics; **KEDA does not provide global warm/cold placement.** Use llm-d's documented KEDA+EPP-metrics path, not the old KEDA HTTP Add-on.

| State | Meaning | Intended hub behavior |
|---|---|---|
| Warm | Ready model endpoints exist | Normally eligible |
| Saturated | Ready but overloaded | Avoid when another warm region has capacity |
| Cold | Gateway/EPP healthy; zero model replicas | Eligible only under an explicit policy |
| Waking | Capacity requested; model not ready | Hold or avoid per policy |
| Failed | Gateway/EPP unhealthy/unreachable | Removed from eligible destinations |

**Control-loop warning:** if the hub filters out a cold region completely, that region receives no requests, its queue stays empty, and KEDA may never activate it. K1–K4 are therefore separate tests, not one combined scenario.

| Test | Procedure | Pass evidence |
|---|---|---|
| **K1** | Force traffic to a cold region (hub policy) | Regional EPP queueing observed; KEDA scales 0→1 from EPP metrics; activation latency and held-request outcomes recorded |
| **K2** | One warm, one cold region; unforced policy | Warm region receives traffic; cold region not activated spuriously |
| **K3** | Cold region activated only after warm-capacity overflow or failure | Activation happens under the defined condition, not before |
| **K4** | Both regions cold | Documented behavior (queueing, timeouts, errors) — no silent black-holing |

K1 belongs to the first autoscaling step. **K2–K4 require a feasibility check of regional readiness/health signals and policy mechanics in the pinned version before they are attempted; they are not claimed as inherited KEDA features.** Outcomes are reported as demonstrated / demonstrated-with-custom-policy / not-supported.

---

## 9. Observability and request-correlation design

**Per-request record (JSONL, one line per request):**

```
request_id, client_location, client_send_ts, first_byte_ts, end_ts,
hub_decision {region, decision_source}, regional_decision {endpoint_id},
serving_endpoint, model_identity (name@revision),
hub_queue_ts/schedule_ts (where available), regional_queue_ts/schedule_ts,
ttft_ms, tpot_ms, total_ms, output_tokens,
vllm_prefix_cache_counters {before/after or scrape delta},
status {ok|error|partial_stream}, error_detail, run_id
```

Mechanisms:

- **Correlation ID:** client-generated request ID; transported via W3C trace context (EPP propagates W3C traces in v1.0.0, router #2702). Whether a custom ID header survives forwarding is a G1 item-10 question — until verified, correlation relies on trace IDs + timestamp-ordered authoritative logs/metrics, never on invented response headers.
- **Hub decision:** hub EPP scheduling logs/metrics + trace spans; destination identity from the multicluster discovery file version used in the run.
- **Regional decision / serving endpoint:** regional EPP decision evidence; simulators identify themselves in responses (G1 item 9); vLLM pods identified via logs/metrics labels.
- **Latency:** client-side TTFT/TPOT/total + EPP queue-duration histograms (exemplars exist in v1.0.0) for cross-checking.
- **Cache truth:** vLLM prefix-cache counters scraped from the pinned v0.30.0 image (exact metric names fixed in G1 item 10) — TTFT alone is not cache evidence.
- **Run metadata:** `run_id` → routing-policy version, component versions (`versions.lock`), model revision, cluster state, ready-endpoint counts, failure-injection timestamps, load-generator config.
- **Storage:** `docs/results/<phase>/<run-id>/` (JSONL + scrapes + analysis note); committed to the repo.

---

## 10. Security, data movement, quota, and cost

- **Authentication/authorization:** hub and spoke gateways behind HTTPS with auth (baseline bearer-token pattern or mTLS — decided P2); no unauthenticated model endpoints; cluster API servers restricted to authorized networks; Workload Identity everywhere (baseline pattern).
- **Cross-cluster telemetry:** mTLS for hub→spoke metrics (upstream defaults to server verification, router #2232); certificates provisioned per A13 with a documented rotation procedure (restart-based until upstream hot-reload ships); least-privilege scrape path (metrics port only).
- **Data movement:** hub→spoke requests move prompt data across EU/US jurisdictions; this PoC makes **no data-residency claim**; synthetic test prompts only; noted in the final report.
- **Quota:** L4 GPU quota verified in both zones at P2 entry (and re-verified at P5); Spot preemption handled by test retry policy and recorded as an environmental event, not a routing failure.
- **Cost:** zonal clusters (free control plane); always-on cost ≈ 2 × `e2-standard-4`; GPUs warm only during scheduled test windows, scaled to 0 otherwise (A16); KEDA phase is the cost-optimization evaluation, not a prerequisite; WAN egress measured (VPC flow logs / billing export) and reported; budget alert configured at P2; full teardown verified at P8. **User constraint (2026-11-11): every test window — including waits — is capped at 30 minutes** to protect both token and GCP budgets; load tests, GPU warm windows, and failure-injection runs are sized and split accordingly, and long-running operations are parallelized where safe.

---

## 11. Risk register

| # | Risk | Mitigation | Residual limitation |
|---|---|---|---|
| R1 | US-colocated hub is a single point of failure and adds EU latency | Accepted for scope; measured honestly in T9 | Hub HA out of scope (A10); documented |
| R2 | One hub cannot infer client geography | Out of scope; forcing is config-driven (A9) | No automatic geography routing claimed |
| R3 | Cross-cluster telemetry staleness degrades routing/failure detection | Refresh/timeout settings recorded; T4 sub-test 4 measures the metrics-gap case | Detection window is nonzero by design; measured, not hidden |
| R4 | Forced regional migration loses warm cache | Expected consequence; T6/T7 quantify cold→warm transition | First request after failover is normally cache-cold |
| R5 | One real endpoint/region cannot prove pod-level selection | Env A (2 sims/region) supplies that proof (T5); optional second real endpoint documented as extension | GPU-backed two-level cache routing only spot-checked (T8) |
| R6 | Scale-to-zero complicates readiness/timeouts/cache | Deferred to P7 behind G5; K1 first; state model in §8 | K2–K4 conditional on feasibility check |
| R7 | Data residency | Synthetic prompts; explicit no-claim statement | Jurisdictional guarantees need separate policy design |
| R8 | Cost/egress overrun | Test windows, scale-to-0 between, budget alert, P8 verified teardown | Estimates deferred to measurement |
| R9 | Reachable endpoint ≠ healthy schedulable destination | G1 item 6 defines eligibility semantics; T4 exercises each failure mode | Some failure modes may need custom policy — reported as such |
| R10 | Global load-balancing success mistaken for two-level routing proof | T5 negative control mandatory | — |
| R11 | **Fail-open masking an EPP outage** (router #3433): gateway keeps routing when regional EPP is down | T4 sub-test 2 explicitly detects fail-open vs. healthy scheduling via decision evidence | If fail-open is not configurable at the pinned version, limitation documented |
| R12 | Simulator telemetry drifts from real vLLM behavior | A7 gated at G1/P3; all functional conclusions re-spot-checked on Env B | Sim-derived timings never reported as real inference performance |
| R13 | Header stripping (router #3090) breaks a harness assumption | G1 items 3/10 fix the correlation and forcing mechanisms before any test | Custom client headers may be unusable |
| R14 | Spot L4 preemption mid-measurement | Retry policy; preemption logged as environmental event | Some runs invalidated and repeated |
| R15 | v1.0.0 multicluster path immature: all eight `multicluster-*` plugins are **StabilityAlpha** at v1.0.0 (`cmd/epp/runner/runner.go`) — no backwards-compat guarantee; hub requires `--allow-experimental-plugins` | G1 source verification done; exact pin in `versions.lock`; behavior recorded per run; fallback version path (§5) | Bugs found during PoC are filed upstream and documented |
| R16 | Metrics cert rotation causes hub blind spots | Restart-based rotation runbook (A13) until upstream hot-reload (#2045/#2151) ships | Brief telemetry gaps during rotation |

---

## 12. Proposed minimal repository layout

Created phase by phase — nothing is scaffolded before its gate:

```
llm-d-cross-region-poc/
├── PLAN.md                        # this document
├── versions.lock                  # frozen at P1; single version source of truth
├── docs/
│   ├── source-baseline.md         # P0: G0 record
│   ├── version-evidence.md        # P1: G1 evidence pack
│   ├── architecture.md            # P2: as-built network/DNS/TLS decisions
│   ├── final-report.md            # P8
│   └── results/<phase>/<run-id>/  # JSONL records, scrapes, analysis notes
├── infra/
│   ├── modules/                   # P2: network + cluster, adapted from vllm-gke
│   └── environments/{eu,us}/      # P2: per-region tfvars (CIDRs per §4)
├── k8s/
│   ├── hub/                       # P4: hub EPP config, discovery file
│   ├── region-eu/                 # P3/P5: gateway, EPP, InferencePool, sim/vLLM values
│   └── region-us/                 # P3/P5
└── tests/                         # P4+: request generators, correlation tooling
```

---

## 13. Implementation-readiness checklist

Before P2 (first cloud resource):

- [ ] G0 signed off: source state recorded; `vllm-gke` confirmed untouched and independent
- [ ] G1 evidence pack complete; every required capability has a version-tagged citation or an explicit limitation
- [ ] `versions.lock` frozen (incl. model HF revision SHA)
- [ ] Hub + regional draft configs reviewed and committed
- [ ] Regions/zones fixed; L4 quota and Spot capacity verified in both
- [ ] CIDR plan validated against existing `vllm-vpc`
- [ ] DNS/TLS/cert decisions recorded (A12, A13)
- [ ] Budget alert configured; teardown runbook drafted
- [ ] Explicit user approval for P2 `terraform apply`

Before each later phase: its entry criteria (§6) and a fresh approval for the actions it introduces.
