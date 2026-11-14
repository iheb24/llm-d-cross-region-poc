# llm-d-cross-region-poc — Agent Instructions

This repo evaluates llm-d as a two-level (hub → region → endpoint) inference
router across two GKE clusters. It is an evaluation, not a production stack:
everything is rebuilt and torn down repeatedly. Follow these rules strictly.

## 1. Security & secrets
- **Never** hardcode secrets, API keys, tokens, or static SA credentials.
  tfvars stay gitignored (`*.tfvars`); only `*.tfvars.example` with placeholders
  is tracked. `terraform.tfstate` and `.terraform/` are never committed.
- Pods authenticate via **Workload Identity** only.
- Pre-commit is mandatory (`pre-commit install`): gitleaks, trivy, tflint,
  checkov, conventional commits, hygiene hooks, and `scripts/check-boundary.sh`.
  Every checkov skip must be an inline, individually justified comment
  (`# checkov:skip=CKV_GCP_XX: reason`); no blanket skip lists.
- **Public exposure is an exception, not a default.** Any new public surface
  (LoadBalancer service, `loadBalancerIP`, `0.0.0.0/0`) must carry a
  `# boundary-ok: <reason>` comment referencing
  `docs/risk-note-public-gateways.md`. The baseline (`vllm-gke`) posture —
  private gateway with API key — is the default to mirror.

## 2. Terraform & declarative discipline
- All infrastructure mutations go through Terraform (or committed manifests).
  Manual `gcloud`/`kubectl`/`helm` changes are allowed only as test procedures
  (load generation, failure injection, policy swaps) and must be documented in
  the test evidence. "Quick manual fixes" are the known failure mode of this
  project — if you run one, immediately convert it to a declaration.
- State: GCS backend `project-tf-states`, prefix `llm-d-cross-region-poc/*`.
- Keep modules parameterized: region, zone, CIDRs, machine types, accelerator,
  node counts, replica limits.

## 3. Version pinning
- Everything pinned in `versions.lock` (llm-d v1.0.0, vLLM v0.30.0, GAIE
  v1.6.2, Envoy Gateway v1.8.1 + AI Gateway v0.7.0, inference-sim v1.0.0,
  model `Qwen/Qwen2.5-Coder-14B-Instruct-AWQ@eb3172f`, terraform provider).
  No `latest` anywhere. Version changes reopen gate G1 (see PLAN.md §5).

## 4. Approvals & budget
- `terraform apply/destroy`, `kubectl apply/delete` on shared infrastructure,
  and any destructive command require explicit user approval at execution time.
- Test windows (including waits) are capped at ~30 minutes; GPU pools stay
  warm only during test windows; full teardown must be verified
  (zero instances/clusters/disks/NEGs — sweep ILB NEG and PVC leaks).

## 5. Evidence
- Every test run records: policy version, component versions, cluster state,
  ready-endpoint counts, injection timestamps. Evidence lives in
  `docs/results/<phase>/`. A successful HTTP response alone is never accepted
  as proof of the intended route. Limitations are documented, not worked
  around silently.

## 6. Baseline relationship
`vllm-gke` is a separate project — never modify it. Its posture (pre-commit,
Workload Identity, private gateway + API key, aggressive gitignore,
conventional commits) is mirrored here, not shared.
