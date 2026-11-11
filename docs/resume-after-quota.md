# Resume runbook — after GPU quota approval

Written 2026-11-11 at teardown. Everything needed is in this repo; a full
rebuild + revalidation takes ~40 minutes (proven once already during the
region move).

## Why we tore down

- **Binding constraint:** `GPUS_ALL_REGIONS = 1` **globally** (project-level)
  — only one L4 VM can exist at a time. Regional quotas are fine
  (`NVIDIA_L4_GPUS=1`, `PREEMPTIBLE_NVIDIA_L4_GPUS=1` per region).
  Evidence: autoscaler event `Quota 'GPUS_ALL_REGIONS' exceeded. Limit: 1.0 globally.`
- Needed for Env B: `GPUS_ALL_REGIONS >= 2` (quota increase submitted by the user 2026-11-11).
- Capacity note: on 2026-11-11, L4 was exhausted in us-central1-a/b/c/f and
  europe-west4-a/b/c for both spot and on-demand, g2-standard-8 and -4.
  Working zones found by probe: **europe-west1-b, us-east1-c** (clusters now
  point there; re-probe before apply if days pass — zones are cheap to change).

## State at teardown

- Destroyed: both clusters (incl. GPU pools), gateways, static IPs (terraform `destroy` in `eu/`, `us/`, then `network/`).
- Intact: this repo (terraform, manifests, helm values, scripts, all P1–P4 evidence in `docs/results/`), `vllm-gke` untouched.
- Lost on rebuild: nothing stateful — sims are stateless; vLLM model weights re-download (~10 GB, ~10 min); IPs change (see step 4).

## Resume steps

```bash
# 0. Verify quota: GPUS_ALL_REGIONS >= 2
gcloud compute project-info describe --project=project-c4f86d90-75ff-4766-8cd \
  --format=json | python3 -c "import json,sys; [print(q['metric'],q['limit'],q['usage']) for q in json.load(sys.stdin)['quotas'] if q['metric']=='GPUS_ALL_REGIONS']"

# 1. Recreate infra (parallel eu+us after network)
cd infra/environments/network && terraform init && terraform apply
cd ../eu   && terraform init && terraform apply &   # ~10 min
cd ../us   && terraform init && terraform apply &
wait

# 2. Credentials (contexts come back as gke_...; rename to llmd-poc-eu/us)
gcloud container clusters get-credentials llmd-poc-eu --zone europe-west1-b --project project-c4f86d90-75ff-4766-8cd
gcloud container clusters get-credentials llmd-poc-us --zone us-east1-c      --project project-c4f86d90-75ff-4766-8cd

# 3. Gateway stack + GMP (both clusters)
k8s/install-spoke.sh llmd-poc-eu
k8s/install-spoke.sh llmd-poc-us
gcloud container clusters update llmd-poc-eu --zone europe-west1-b --enable-managed-prometheus
gcloud container clusters update llmd-poc-us --zone us-east1-c      --enable-managed-prometheus

# 4. New IPs -> manifests (terraform output gives the new addresses;
#    sed them into these files, replacing the 2026-11-11 values):
#    k8s/region-eu/envoyproxy.yaml  (loadBalancerIP = eu gateway_ip)
#    k8s/region-us/envoyproxy.yaml  (loadBalancerIP = us gateway_ip)
#    k8s/hub/gateway.yaml           (loadBalancerIP = us hub_gateway_ip)
#    k8s/hub/clusters.yaml          (address: eu/us gateway_ip)

# 5. Workloads per region (ns + envoyproxy + gateway + sim + vllm + monitors + ILB + router)
#    then hub (configmap + gateway + helm) — exact commands mirror git history
#    (see commit messages around the region move, 2026-11-11).

# 6. Revalidate: direct-spoke 200s both regions, hub 200, then resume P5:
#    vLLM ready both regions -> switch regional routers to router-values.envB.yaml
#    -> direct-spoke + via-hub validation -> tests/t6_prefix_cache.py
```

## Invariants (do not re-derive)

- versions.lock pins everything; llm-d-router v1.0.0 contains the multicluster plugins (alpha — keep `allow-experimental-plugins`).
- GKE: Gateway `spec.addresses` does NOT bind IPs (externalIPs denied) — use the EnvoyProxy patch (already in the files).
- vLLM on g2-standard-4 (16 GB) needs `--enforce-eager` (dynamo OOMs) and ≤14Gi pod limit.
- vLLM pods need the `nvidia.com/gpu` toleration and `strategy: Recreate` (one GPU per region).
- EPP chart defaults request 8 CPU — keep the 500m override in the values files.
