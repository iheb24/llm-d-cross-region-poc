# P2 evidence — regional cluster skeletons (applied 2026-11-11)

## Applied resources

| Environment | Resources | Duration | Outputs |
|---|---|---|---|
| `network` | 7 (VPC `llmd-poc-vpc`, 2 subnets + secondary ranges, 2 router/NAT) | ~50 s | `network-outputs.json` |
| `eu` | 5 (cluster `llmd-poc-eu`, system pool, SA, WI binding, static IP) | ~9.5 min | `eu-outputs.json` |
| `us` | 6 (cluster `llmd-poc-us`, system pool, SA, WI binding, 2 static IPs) | ~10.7 min (parallel) | `us-outputs.json` |

## Verified exit criteria

- Both clusters reachable; 1 × Ready `e2-standard-4` system node each; Kubernetes `v1.36.4-gke.2377000` (recorded in `versions.lock`).
- kubectl contexts renamed for ergonomics: `llmd-poc-eu`, `llmd-poc-us`.
- CIDRs verified live against plan and against the existing `vllm-vpc` (no overlap):
  - EU: nodes `10.10.0.0/20`, pods `10.12.0.0/14` (`eu-gke-pods`), services `10.18.0.0/20` (`eu-gke-services`), master `172.16.0.16/28`
  - US: nodes `10.20.0.0/20`, pods `10.24.0.0/14` (`us-gke-pods`), services `10.28.0.0/20` (`us-gke-services`), master `172.16.0.32/28`
  - (GKE auto-created `gke-llmd-poc-*-pe-subnet` ranges for the masters — expected, non-overlapping.)
- Reserved addresses: EU gateway `34.34.96.149`; US gateway `34.70.139.142`; hub gateway `146.148.64.26` (US).

## Cost posture

Idle ≈ 2 × `e2-standard-4` + 3 static IPs; no GPU pools exist (`gpu_pool_enabled=false` until P5). Teardown route: `terraform destroy` in `us`, `eu`, then `network` (approval required).

## Notes for P3

- Gateway Services in each region must bind the reserved IPs above (load-balancer IP annotations).
- AI Gateway v0.7.0 / Envoy Gateway v1.8.1 + GAIE v1.6.2 CRDs per `versions.lock`; GKE pre-installed CRD state to be checked at P3 (version-evidence.md §8 residual).
