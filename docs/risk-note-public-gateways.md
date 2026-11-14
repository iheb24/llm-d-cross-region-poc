# Risk note — public inference gateways (exposure window & closure)

## What was exposed (2026-11-11 → 2026-11-14, while the stack was up)

Three external load-balancer IPs — EU spoke gateway, US spoke gateway, hub
gateway — served **unauthenticated HTTP :80** OpenAI-compatible inference to
the entire internet. No API key, no WAF, no rate limiting, no TLS.

What an internet party could have done:

- **Spend our money**: run arbitrary prompts against the real vLLM (spot L4,
  ~$0.25/h while warm) and the sims. Worst case ≈ $6/day per node while warm.
- **DoS** the small system nodes with load.
- Read sim responses (fake text) — **no real data, prompts, or credentials
  were exposed**: PoC traffic is synthetic, and no auth material exists in the
  request path at all.

What was **not** exposed: pod/node IPs (private nodes, NAT-only egress), VPC
internals, the EPP metrics plane (VPC firewall, pod ranges only), and the GKE
control planes (public endpoint restricted by authorized-networks to the
operator IP). All static IPs were released at teardown.

## Why it happened

Cross-region hub mode needs the hub (US) to reach spoke gateways; GKE internal
LBs are **region-local**, so naive ILBs can't work (we hit the same wall with
metrics). Public LBs were the fast path; the baseline `vllm-gke` posture
(ClusterIP-only gateway + Bearer API key) is the better default we diverged
from for convenience. Noted and fixed on 2026-11-14.

## The closure (current posture)

- Every gateway's Envoy Service sets **`spec.loadBalancerSourceRanges`** to
  exactly `{operator IP, PoC Cloud NAT egress IPs}` (see
  `k8s/*/envoyproxy.yaml`, maintained by `scripts/repoint-ips.sh`). GKE scopes
  the L4 firewall to those sources: the gateways answer only the operator and
  hub traffic. Verified by curl from an unauthorized source (blocked) vs the
  operator (200) after every rebuild.
- `scripts/check-boundary.sh` (pre-commit) fails on any new public surface
  without an inline `# boundary-ok:` reason referencing this note.
- HTTPS + API-key at the gateway (app-layer auth) and fully-private spokes via
  Private Service Connect / IAP are recorded as adoption-time alternatives;
  the ILB region-locality constraint makes the latter a real redesign.

## Rules going forward

1. No new public surface without a `# boundary-ok:` marker + a doc entry here.
2. IP changes go through `scripts/repoint-ips.sh` (never hand-edited in
   terraform/state or manually via gcloud).
3. Exposure posture is re-verified at every rebuild validation
   (`tests/showcase.sh` health probes run from the operator; a blocked-source
   curl is part of the verify step in the runbook).
