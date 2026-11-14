# llm-d Cross-Region PoC

An evaluation of **llm-d v1.0.0** as a hierarchical inference-routing layer across
two GKE clusters in different regions: a **hub** Endpoint Picker (EPP) chooses a
regional destination, and a **regional** EPP chooses a local inference endpoint.

This is an evaluation, not a commitment to adopt: it optimizes for clear
evidence, controlled scope, reproducibility, and easy teardown.

## Results at a glance

| Claim | Verdict |
|---|---|
| Deterministic regional selection (T1) | Proven: 20/20 forced EU, 20/20 forced US |
| Weighted regional routing (T2) | Proven: 159/40 vs 159.2/39.8 expected |
| Two-level routing hub → region → endpoint (T5) | Proven per request + negative control |
| Prefix-cache reuse, real counters (T6) | Cold 3.09 s → warm 0.42 s, `vllm:prefix_cache_hits_total` +4096 |
| Multi-turn affinity (T7) | 3/3 pinned turns, 84–87 % tokens reused/turn |
| Latency overhead (T9) | hub ≈ +1 ms local; +274 ms cross-region |
| Failure windows (T4) | gateway ~34 s / ~23 s; pool-down 3m04s cold start |
| Preferred-region overflow (T3) | Demonstrated with a synthetic pressure ramp |
| Automatic failover (hub reroutes around a dead region) | **Not demonstrated** — no request-outcome feedback at hub level in v1.0.0 multicluster |

Full analysis: [docs/final-report.md](docs/final-report.md).
Evidence records: `docs/results/`.

## Stack

- **llm-d v1.0.0** (router EPP, InferencePool, inference-sim), vLLM v0.30.0
- GAIE / Gateway API v1.6.2, Envoy Gateway v1.8.1 + Envoy AI Gateway v0.7.0
- GKE (zonal clusters), Terraform (network + cluster modules), Helm, GMP
- Simulators first (functional routing), then one real L4 vLLM (hybrid design;
  `GPUS_ALL_REGIONS = 1` project-wide in this GCP project)

## Reproduce

Follow [docs/architecture-and-reproduction.md](docs/architecture-and-reproduction.md):
capacity probe → terraform (network, eu, us) → credentials → spoke install →
`scripts/repoint-ips.sh` → workloads → source-lock verification →
`tests/showcase.sh` for the end-to-end feature tour. Full teardown per the same
document (verified zero residue, repeatedly).

## Repo layout

- `PLAN.md` — evaluation plan, phases, gates, risks
- `versions.lock` — every pinned version (no `latest` anywhere)
- `infra/` — terraform (network, cluster modules; eu/us/network environments)
- `k8s/` — gateways, EPP configs (hub/region), sims, vLLM, monitoring
- `tests/` — the harness: `showcase.sh` + per-feature scripts (t1…t9)
- `docs/` — source baseline, version evidence (G1), final report,
  risk note on public gateways, results per phase
- `dashboards/` — Cloud Monitoring evidence dashboard (also a terraform resource)
- `scripts/` — `repoint-ips.sh`, `check-boundary.sh`, `scrub-operator-ip.sh`

## Security posture

Pre-commit enforced: gitleaks, trivy, tflint, checkov, conventional commits,
plus `scripts/check-boundary.sh` (fails on unreviewed public exposure).
Gateways are source-locked (`loadBalancerSourceRanges`: operator IP + reserved
NAT egress + pod CIDRs) — see [docs/risk-note-public-gateways.md](docs/risk-note-public-gateways.md).
Rules for contributors and agents: [AGENTS.md](AGENTS.md).

## License

MIT — see [LICENSE](LICENSE).
