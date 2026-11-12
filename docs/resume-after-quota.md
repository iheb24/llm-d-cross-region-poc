# Rebuild runbook — resume PoC after evening teardown (2026-11-12)

Everything needed is in this repo. Full rebuild ≈ 40 min, mostly unattended.
State at teardown: **Env B-hybrid complete through G4** (P1–P6 done; P7 KEDA
optional, P8 final report pending). GPU constraint is permanent until quota
changes: `GPUS_ALL_REGIONS = 1` project-wide → exactly one L4 at a time;
hybrid design puts it in the US cluster, EU stays on sims.

## 0. Pre-flight (2 min)

```bash
# capacity probe (spot g2-standard-4) in the working zones:
for z in us-east1-c europe-west1-b; do
  gcloud compute instances create probe-$z --zone=$z --machine-type=g2-standard-4 \
    --provisioning-model=SPOT --instance-termination-action=DELETE \
    --project=project-c4f86d90-75ff-4766-8cd && gcloud compute instances delete probe-$z --zone=$z --quiet
done
# If exhausted: probe us-east1-b/d, europe-west1-c/d; edit region/zone in
# infra/environments/{eu,us,network}/main.tf before applying.
```

## 1. Infra (≈12 min, parallel)

```bash
cd infra/environments/network && terraform init && terraform apply
cd ../eu && terraform apply & cd ../us && terraform apply & wait
# EU: system pool only (no GPU). US: spot g2-standard-4 min 1 (GPU node comes up with the cluster).
```

## 2. Credentials + gateway stack (≈5 min, parallel)

```bash
gcloud container clusters get-credentials llmd-poc-eu --zone europe-west1-b --project project-c4f86d90-75ff-4766-8cd
gcloud container clusters get-credentials llmd-poc-us --zone us-east1-c      --project project-c4f86d90-75ff-4766-8cd
kubectl config rename-context <gke_..._eu> llmd-poc-eu   # if needed
kubectl config rename-context <gke_..._us> llmd-poc-us
k8s/install-spoke.sh llmd-poc-eu
k8s/install-spoke.sh llmd-poc-us
gcloud container clusters update llmd-poc-eu --zone europe-west1-b --enable-managed-prometheus
gcloud container clusters update llmd-poc-us --zone us-east1-c      --enable-managed-prometheus
```

## 3. IPs → manifests (2 min)

Static IPs change on rebuild. Read `terraform output` per env and sed into:

| File | Field |
|---|---|
| `k8s/region-eu/envoyproxy.yaml` | `loadBalancerIP` = eu `gateway_ip` |
| `k8s/region-us/envoyproxy.yaml` | `loadBalancerIP` = us `gateway_ip` |
| `k8s/hub/gateway.yaml` | `loadBalancerIP` = us `hub_gateway_ip` |
| `k8s/hub/clusters.yaml` | `address:` eu/us gateway IPs |
| `tests/*.sh`, `tests/*.py` | `HUB`/`HUB_IP` constants |
| `k8s/hub/clusters.yaml` | `metricsAddress` = **system node internal IPs** (`kubectl get nodes -o wide`), `metricsPort: "30090"` |

## 4. Workloads (≈5 min + ~10 min model download)

Per region (EU first): `create ns llmd-serving` → `envoyproxy.yaml` → `gateway.yaml` →
sims (`k8s/region-eu/sim.yaml` for EU — real model name; `k8s/region/sim.yaml` for US) →
`podmonitoring.yaml` (+ `region-us/vllm-podmonitoring.yaml` in US) →
`region-*/metrics-nodeport.yaml` → router helm (`k8s/region/router-values.yaml` EU,
`router-values.envB.yaml` US — US points at the real vLLM).
Then vLLM in US (`k8s/region/vllm.yaml`), hub (configmap + `k8s/hub/gateway.yaml` +
`k8s/hub/router-values.yaml`). Exact command sequence: see git history of 2026-11-12.
Firewall rule (hub's cross-cluster scrape): recreate
`llmd-poc-xcluster-metrics` (tcp:9090,30090 from 10.12.0.0/14,10.24.0.0/14) if not
moved into terraform by then.

## 5. Validate + continue

```bash
tests/showcase.sh            # ~5-min feature tour; expect all PASS
```

Then: P7 (KEDA — needs `featureGates: ["flowControl"]` on the regional EPP,
finding F2) and/or P8 (final report + teardown).

## Invariants (hard-won, do not rediscover)

- **GPU:** one L4 project-wide; spot g2-standard-4 (16 GB) → vLLM needs
  `--enforce-eager` and ≤14 Gi pod limit; GPU toleration; `strategy: Recreate`.
- **Gateway:** `spec.addresses` fails on GKE (externalIPs denied) → EnvoyProxy
  `loadBalancerIP` patch (class-level for regional, per-Gateway `infrastructure.parametersRef` for hub; no namespace field in v1).
- **EPP:** chart default requests 8 CPU — keep 500m override. All `multicluster-*`
  plugins are alpha → `allow-experimental-plugins`. Flow control is OFF by
  default (`featureGates: ["flowControl"]`). Tie-pin direction is unstable per boot.
- **Observability:** GMP needs `roles/monitoring.metricWriter` on node SAs;
  vLLM pod needs its own ClusterPodMonitoring; Monitoring timeSeries API needs
  an explicit `interval`. Dashboard id: `ed86ce2c-3d60-4da8-9247-86ec377db398` (rebuilds from `dashboards/llmd-poc.json`).
- **Sims:** EU sims serve the REAL model name (T3/T7/T9 evidence); sim ctx
  `--max-model-len=8192`; `x-inference-pod` header is sim-emitted (not present
  on real vLLM responses — use EPP metadata/logs there).
- **Evidence:** all test JSONL lives in `docs/results/p4|p5|p6/`; PLAN.md §P5
  records the hybrid design and its claim boundaries.
