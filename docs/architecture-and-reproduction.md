# llm-d Cross-Region PoC — Architecture & Reproduction Guide

This document describes the deployed architecture and gives the exact steps to
rebuild the stack and conduct each test. Read `PLAN.md` for the evaluation
design, `docs/final-report.md` for results, and
`docs/risk-note-public-gateways.md` for the security posture rationale.

## 1. Architecture

### Request path

```
client (operator IP only)
  │
  ▼
hub gateway (Envoy AI Gateway, LB VIP, source-locked)      [US cluster]
  │  ext-proc → hub EPP (llm-d-router v1.0.0, multicluster-* plugins)
  │  candidates = regional gateways from k8s/hub/clusters.yaml (file discovery)
  │  scores: region preference weights, pool queue size, pool KV util,
  │          session affinity (x-session-token)
  ▼
regional gateway (Envoy AI Gateway, LB VIP, source-locked) [EU or US cluster]
  │  ext-proc → regional EPP (pool scorers: queue, KV util, prefix cache,
  │             session affinity)
  ▼
regional InferencePool endpoints
  EU: 2 × llm-d-inference-sim        (Env A / hybrid cold-reference)
  US: 1 × real vLLM v0.30.0 on 1× L4 (+ parked sims; + optional pressure-sim)
```

### Source-locked gateways (current security posture)

Every gateway's Envoy Service sets `spec.loadBalancerSourceRanges` to exactly
`{operator IP, reserved NAT egress IPs, both PoC pod CIDRs}`:

- **operator → any gateway**: allowed.
- **hub → spokes**: intra-VPC (same region) keeps the pod source IP (pod CIDRs
  allowed); cross-region egresses via the US reserved NAT IP (allowed).
- **any other source**: dropped by the GKE-managed LB firewall (verified by
  probe: connection times out).

NAT egress uses **reserved static IPs** (`google_compute_address` +
`MANUAL_ONLY` in the network module) because auto-allocated NAT IPs are
ephemeral and unsafe to allowlist. Reserved IPs are released at teardown and
change per rebuild — `scripts/repoint-ips.sh` re-derives everything.

### Telemetry plane (hub's cross-cluster signals)

- Each regional EPP exports pool aggregates: `llm_d_epp_average_queue_size`,
  `llm_d_epp_average_kv_cache_utilization` (from per-pod vLLM/sim metrics).
- The hub scrapes both via `multicluster-metrics-data-source` over a
  **NodePort (30090) on each region's system node**, allowed by the
  `llmd-poc-xcluster-metrics` firewall rule — **declared in terraform**
  (`infra/modules/network/google_compute_firewall.xcluster_metrics`).
  (GKE ILB VIPs are region-local; NodePort is the working path.)
- Per-cluster metrics flow to Google Managed Prometheus (enabled in terraform
  via the cluster module's `monitoring_config.managed_prometheus`; scraped via
  ClusterPodMonitoring for EPP, sims, and the vLLM pod). The evidence dashboard
  is also a terraform resource (`infra/environments/network/dashboard.tf`).
- The node SAs carry `roles/monitoring.metricWriter` (terraform IAM member).

### Key deployment facts (learned the hard way — don't rediscover)

- All `multicluster-*` plugins are StabilityAlpha → hub EPP runs
  `--allow-experimental-plugins`; pin everything (no `latest`).
- EPP chart default requests 8 CPU → override to 500m for the e2-standard-4 system node.
- GKE Gateway `spec.addresses` fails (externalIPs denied) → bind static IPs via
  EnvoyProxy `envoyService.patch` `loadBalancerIP`: class-level for regional
  gateways, per-Gateway `infrastructure.parametersRef` for the hub gateway.
- vLLM on g2-standard-4 (16 GB): `--enforce-eager` (torch.compile OOMs),
  pod memory ≤14 Gi, GPU toleration `nvidia.com/gpu:NoSchedule`, `strategy: Recreate`.
- Sim context default 1024 tokens → set `--max-model-len=8192` for long prefixes.
- Sim `x-inference-pod`/`x-session-token` headers are sim-emitted; real vLLM
  responses don't carry pod identity.
- llm-d flow control is feature-gated OFF by default (`featureGates: ["flowControl"]`).
- `sim --fake-metrics` must be present at startup for runtime `/admin/config`
  ramps; generator values use `func:start:end:period`, fixed values are numbers.
- Intra-VPC traffic to an external LB VIP does NOT traverse the Cloud NAT —
  it keeps the pod source IP (this is why pod CIDRs are in the source ranges).

## 2. Reproducing the stack

Prereqs: gcloud + kubectl + terraform + helm on the operator machine; a GCP
project with 1 L4 GPU (project-wide) and per-region L4 quotas.

```bash
# 0) Clone this repo; set secrets; install the toolchain (once per machine)
cd llm-d-cross-region-poc
for e in network eu us; do cp infra/environments/$e/terraform.tfvars.example infra/environments/$e/terraform.tfvars; done
#   fill project_id (all three) and my_public_ip (eu/us)
pre-commit install && pre-commit install --hook-type commit-msg
pre-commit run --all-files   # must be green before anything is applied

# 1) Capacity probe for the GPU zone (spot g2-standard-4); change regions/zones in
#    infra/environments/*/main.tf if probing elsewhere, keeping CIDRs as-is.
#    NOTE: probe only AFTER any teardown has fully completed — a GPU node still
#    draining holds the single project-wide GPU slot and makes probes falsely
#    report exhaustion (observed 2026-11-13).
gcloud compute instances create probe-$ZONE --zone=$ZONE --machine-type=g2-standard-4 \
  --provisioning-model=SPOT --instance-termination-action=DELETE --project=$PROJECT \
  && gcloud compute instances delete probe-$ZONE --zone=$ZONE --quiet

# 2) Infra (~12 min; now includes the xcluster firewall rule, reserved NAT IPs,
#    GMP enablement, metricWriter IAM, and the evidence dashboard)
cd infra/environments/network && terraform init && terraform apply && cd ../..
( cd infra/environments/eu && terraform init && terraform apply ) &
( cd infra/environments/us && terraform init && terraform apply ) &
wait

# 3) Credentials (rename contexts to llmd-poc-eu / llmd-poc-us)
gcloud container clusters get-credentials llmd-poc-eu --zone europe-west4-b --project $PROJECT
gcloud container clusters get-credentials llmd-poc-us --zone us-east1-c      --project $PROJECT

# 4) Gateway stack per cluster (GMP is terraform-managed; nothing else to enable)
k8s/install-spoke.sh llmd-poc-eu
k8s/install-spoke.sh llmd-poc-us

# 5) Repoint all IP-bearing files in one step (gateway IPs, NAT egress IPs,
#    operator IP, loadBalancerSourceRanges, clusters.yaml, test constants)
./scripts/repoint-ips.sh

# 6) Workloads (EU: sims only; US: sims + vLLM + hub)
kubectl --context llmd-poc-eu create namespace llmd-serving
kubectl --context llmd-poc-eu apply -f k8s/region-eu/envoyproxy.yaml -f k8s/region-eu/gateway.yaml \
  -f k8s/region-eu/sim.yaml -f k8s/region/podmonitoring.yaml -f k8s/region-eu/metrics-nodeport.yaml \
  -f k8s/region/networkpolicy.yaml
helm upgrade -i llmd-router oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 \
  --kube-context llmd-poc-eu -n llmd-serving -f k8s/region/router-values.yaml

kubectl --context llmd-poc-us create namespace llmd-serving
kubectl --context llmd-poc-us apply -f k8s/region-us/envoyproxy.yaml -f k8s/region-us/gateway.yaml \
  -f k8s/region/sim.yaml -f k8s/region/vllm.yaml -f k8s/region/podmonitoring.yaml \
  -f k8s/region-us/vllm-podmonitoring.yaml -f k8s/region-us/metrics-nodeport.yaml \
  -f k8s/region/networkpolicy.yaml
helm upgrade -i llmd-router oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 \
  --kube-context llmd-poc-us -n llmd-serving -f k8s/region/router-values.envB.yaml
kubectl --context llmd-poc-us -n llmd-serving create configmap llmd-hub-clusters --from-file=k8s/hub/clusters.yaml
kubectl --context llmd-poc-us apply -f k8s/hub/gateway.yaml
helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 \
  --kube-context llmd-poc-us -n llmd-serving -f k8s/hub/router-values.yaml
# (pressure-sim.yaml is applied only for T3 runs; it scales to 0 by default)

# 7) The hub's cross-cluster metrics firewall is terraform-managed — nothing to run.

# 8) Verify the source lock (expected: blocked source times out, operator 200):
#    - operator:  curl http://<eu-gateway-ip>/v1/models           -> 200
#    - blocked:   create a VM in the default VPC with an external IP and curl
#                 the same URL                                        -> timeout
#    - hub path: POST to the hub gateway /v1/chat/completions         -> 200
```

## 3. Conducting the tests

| Test | Command | Expect |
|---|---|---|
| Smoke all proven features (~10 min) | `tests/showcase.sh` | F1–F6 verdicts; `--with-failure` adds the pool-down probe |
| T1 deterministic | `tests/t1-deterministic.sh eu 20 out.jsonl` then `... us ...` | 20/20 in forced region |
| T2 weighted | `tests/t2-weighted.sh 200 out.jsonl` | split within chi-square tolerance |
| T3 overflow (synthetic pressure) | apply `k8s/region-us/pressure-sim.yaml`, `kubectl --context llmd-poc-us -n llmd-serving scale deploy/llmd-pressure-sim --replicas=1`, wait ready, then `tests/t3-synthetic-pressure.sh <dir>`; scale back to 0 after | US at rest → EU under ramp → US after reset, 100 % 200 |
| T4 failure | `MODEL=Qwen/... tests/probe-loop.sh out.jsonl 2 t4 &` then scale the EU/US envoy deployment or the US vLLM deployment to 0, restore | failure/recovery windows recorded |
| T6 prefix cache | `python3 tests/t6_prefix_cache.py out.jsonl` | cold TTFT ≫ warm; `vllm:prefix_cache_hits_total` jumps on reuse |
| T7 multi-turn | `python3 tests/t7_multiturn.py out.jsonl` | turns pinned; per-turn reuse ≥80 %; migration cold; return warm |
| T9 latency | `python3 tests/t9_latency.py out.jsonl 25` | per-path p50/p95; hub ≈ +1 ms local; +~274 ms cross-region |

Policies live in `k8s/hub/router-values*.yaml` and swap via
`helm upgrade -i llmd-hub ... -f <file>` (a single-replica EPP rollout costs
~1 request at cutover — wait-for-warm before measuring).

## 4. Teardown

```bash
( cd infra/environments/eu && terraform destroy -auto-approve ) &
( cd infra/environments/us && terraform destroy -auto-approve ) &
wait
cd infra/environments/network && terraform destroy -auto-approve
# firewall rule, GMP, IAM bindings, dashboard, and reserved NAT IPs are all
# terraform-managed — they are destroyed by the same commands (reserved NAT IPs
# are released at teardown and re-derived by repoint-ips.sh on the next build).
# sweep leaks: GKE ILB NEGs (k8s2-*) and leftover PVC disks (pvc-*) in the PoC zones;
# verify: gcloud compute instances list / container clusters list = empty.
# The Cloud Monitoring dashboard stays until the network env is destroyed;
# recreate it with terraform apply (free).
```
