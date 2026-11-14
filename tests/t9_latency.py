#!/usr/bin/env python3
"""T9 — latency comparison (Env B-hybrid, client = operator machine, Paris).

Paths (N each, streamed):
  direct-us     : client -> US regional gateway (real vLLM)
  direct-eu     : client -> EU regional gateway (sim)
  hub-us        : client -> hub -> US regional gateway (real vLLM, default policy pins US)
  hub-eu        : client -> hub -> EU regional gateway (sim, force-eu policy)
Reports TTFT/total p50/p95 per path. Cross-region WAN component = hub-eu/direct-eu
comparison; hub overhead = hub-us/direct-us comparison (same backend).
Output: JSONL per request + summary.
"""
import json, statistics, subprocess, sys, time, urllib.request

US_GW, EU_GW, HUB = "34.74.199.152", "104.155.26.156", "34.75.150.223"
REAL, SIM = "Qwen/Qwen2.5-Coder-14B-Instruct-AWQ", "Qwen/Qwen2.5-Coder-14B-Instruct-AWQ"  # both regions serve the real name (EU via sims)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 25
REPO = subprocess.run(["git", "-C", sys.path[0], "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip()
OUT = sys.argv[1] if len(sys.argv) > 1 else f"{REPO}/docs/results/p6/t9-latency.jsonl"
PROMPT = "Explain how a KV cache speeds up inference, in practical terms. " * 8

def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())

def apply_policy(values):
    sh("export DOCKER_CONFIG=$(mktemp -d) && echo '{}' > $DOCKER_CONFIG/config.json && "
       f"helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 "
       f"--kube-context llmd-poc-us --namespace llmd-serving -f {REPO}/k8s/hub/{values} >/dev/null")
    sh("kubectl --context llmd-poc-us -n llmd-serving rollout status deploy/llmd-hub-epp --timeout=180s")
    time.sleep(5)

def send(host, model):
    body = json.dumps({"model": model, "max_tokens": 32, "stream": True,
                       "messages": [{"role": "user", "content": PROMPT}]}).encode()
    req = urllib.request.Request(f"http://{host}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        ttft = None
        for chunk in resp:
            if chunk.strip():
                ttft = time.time() - t0
                break
        total = time.time() - t0
        # drain remaining stream for an honest total
        for _ in resp:
            pass
        total = time.time() - t0
        return resp.status, ttft, total
    except Exception as e:
        return getattr(e, "code", "ERR"), None, time.time() - t0

def run(path, host, model):
    rows = []
    for i in range(N):
        status, ttft, total = send(host, model)
        rows.append({"path": path, "seq": i, "http": status,
                     "ttft_s": round(ttft, 3) if ttft else None, "total_s": round(total, 3),
                     "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    return rows

def pct(vals, p):
    vals = sorted(v for v in vals if v is not None)
    if not vals:
        return None
    k = (len(vals) - 1) * p / 100
    f, c = int(k), min(int(k) + 1, len(vals) - 1)
    return round(vals[f] + (vals[c] - vals[f]) * (k - f), 3)

def main():
    all_rows = []
    for path, host, model, policy in (
            ("direct-us", US_GW, REAL, None),
            ("direct-eu", EU_GW, SIM, None),
            ("hub-us", HUB, REAL, "router-values.yaml"),
            ("hub-eu", HUB, SIM, "router-values.force-eu.yaml")):
        if policy:
            apply_policy(policy)
        rows = run(path, host, model)
        ok = [r for r in rows if r["http"] == 200]
        ttfts, totals = [r["ttft_s"] for r in ok], [r["total_s"] for r in ok]
        summary = {"path": path, "n": len(ok), "errors": len(rows) - len(ok),
                   "ttft_p50": pct(ttfts, 50), "ttft_p95": pct(ttfts, 95),
                   "total_p50": pct(totals, 50), "total_p95": pct(totals, 95)}
        all_rows.append({"summary": summary, "rows": rows})
        print(json.dumps(summary))
    with open(OUT, "a") as f:
        for block in all_rows:
            f.write(json.dumps(block["summary"]) + "\n")
            for r in block["rows"]:
                f.write(json.dumps(r) + "\n")
    apply_policy("router-values.yaml")  # leave default policy active

if __name__ == "__main__":
    main()
