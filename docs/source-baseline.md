# Source Baseline Record (Gate G0)

Recorded 2026-11-11 during P0. Drift re-check performed at P0 start: no drift (details below).

## 1. Source repository state

| Fact | Value |
|---|---|
| Path | `/Users/ihebbesbes/workspace/vllm-gke` |
| Branch | `main` |
| HEAD commit | `eddef67eea47689cf6efc493fdca5bb9c58154c3` (2026-10-29 23:22:08 +0100, "fix(showcases): merge review findings (portability, evidence provenance, test robustness)") |
| Remote | `https://github.com/iheb24/vllm-gke.git` (`origin`, fetch+push) |
| Working tree | Clean; in sync with `origin/main` |
| License | MIT, © 2026 Iheb Besbes (`LICENSE` at repo root) |
| Drift check (2026-11-11) | HEAD still `eddef67…`, no uncommitted changes |

Attribution: the source is the PoC author's own MIT-licensed project. Adapted files retain the MIT notice; no external attribution obligations. This PoC **never modifies** `vllm-gke`; it remains a separate, working project.

## 2. Baseline architecture (as inspected)

Single-zonal GKE cluster in `us-central1-a`:

- Always-on `e2-standard-4` system pool (KEDA, HTTP interceptor, semantic-router stack, CPU SLM).
- Spot NVIDIA L4 GPU pool: `g2-standard-8`, cluster-autoscaler 0–1 nodes.
- `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ` on vLLM (`vllm/vllm-openai:latest` — unpinned), 50 Gi `standard-rwo` PVC, `ClusterIP` service.
- Qwen3-4B Q4_K_M on llama.cpp (CPU tier, always warm).
- Envoy Gateway `v1.8.1` + Envoy AI Gateway `v1.0.0` (pinned in `k8s/install_semantic_routing.sh`); vLLM Semantic Router ExtProc (chart `0.0.0-latest` — unpinned).
- KEDA + KEDA HTTP Add-on (unpinned in `k8s/install_keda.sh`); `HTTPScaledObject` scales the GPU Deployment 0↔1.
- Supporting RAG and showcase components (out of PoC scope).

Routing path: Client → Envoy Gateway / AI Gateway → Semantic Router ExtProc → CPU model **or** KEDA HTTP interceptor → one vLLM GPU endpoint.

## 3. Confirmed limitations driving PoC work

| Limitation | Evidence |
|---|---|
| Region hardcoded to `us-central1` | `infra/environments/dev/main.tf` (module call sites); zone default `us-central1-a` in `infra/modules/vllm-cluster/variables.tf` |
| CIDRs hardcoded | `infra/modules/network/main.tf`: subnet `10.0.0.0/20`, pods `10.4.0.0/14`, services `10.8.0.0/20`; `infra/modules/vllm-cluster/main.tf`: master `172.16.0.0/28` |
| Unpinned model-server image | `k8s/vllm-chart/values.yaml`: `vllm/vllm-openai:latest` |
| Unpinned KEDA install | `k8s/install_keda.sh` (no `--version`) |
| One vLLM replica max (no pod-level selection proof) | GPU pool autoscale 0–1 (`infra/modules/vllm-cluster/main.tf`); `k8s/vllm-chart/values.yaml` `scaling.maxReplicas: 1` |
| Semantic Router does model/tier selection, not region/pod | `k8s/semantic-router/` |
| KEDA HTTP Add-on ≠ llm-d-native scale-from-zero | llm-d documents its own KEDA+EPP-metrics path (PLAN.md §5, §8) |

## 4. Provenance: copied / adapted / new

| Component | Disposition | Notes |
|---|---|---|
| `infra/modules/network` | Adapt | Parameterize region + all CIDRs; new dedicated VPC (existing `vllm-vpc` untouched) |
| `infra/modules/vllm-cluster` | Adapt | Parameterize zone, cluster name, machine types, accelerator, node/replica limits; strip `rag.tf`; keep Workload Identity, private nodes, authorized networks |
| `k8s/vllm-chart` deployment/PVC/SA templates | Adapt | Pin image; EPP/InferencePool integration; regional 50 Gi PVC pattern (model storage stays regional) |
| `k8s/rag/observability` patterns | Reference | Prometheus v3.5.0 / Grafana 11.6.0 / PodMonitoring as starting point |
| `docs/cost-checkpoint.md` | Reference | Cost model extended for 2 clusters + WAN egress |
| Semantic Router, AI Gateway config, CPU SLM, Chat UI, Cline, RAG, showcases, KEDA HTTP Add-on | Not carried | Outside PoC critical path |
| Hub EPP config, multicluster discovery/metrics wiring, simulators, test tooling | New | Built here against pinned llm-d v1.0.0 |

## 5. G0 confirmation items (user sign-off)

- [ ] Source state above is accurate and `vllm-gke` stays independent/unmodified.
- [ ] Goals and non-goals per PLAN.md §1 confirmed.
- [ ] Regions: US `us-central1-a` + EU `europe-west4-a` (default; final zone pending P2 quota/capacity check).
- [ ] Hardware strategy: simulators first (Env A), then 1× Spot L4 per region, always-warm during test windows (Env B); optional second real endpoint later.
