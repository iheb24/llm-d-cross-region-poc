#!/usr/bin/env python3
"""T6 — exact prefix-cache behavior (Env B, real vLLM).

Per PLAN.md §10/T6: a long fixed prefix with short varying suffixes.
  1. force-eu: send prefix P + suffix A -> cold; record region/pod/TTFT/counters
  2. same P + suffix B -> expect affinity hit + vllm:prefix_cache_hits increase
  3. force-us: same-shape fresh prefix P' + suffix A -> cold in US
  4. P' + suffix B -> warm in US
Fresh prefixes per region (nonce) so no cross-trial residue. Output: JSONL.

TTFT = seconds to first streamed byte. Counters read from the serving region's
vllm /metrics via kubectl port-forward.
"""
import json, subprocess, sys, time, urllib.request

HUB = "35.231.239.163"
MODEL = "Qwen/Qwen2.5-Coder-14B-Instruct-AWQ"
MODEL_BY_REGION = {"eu": MODEL, "us": MODEL}  # both regions serve the real name (EU via sims)
CTX = {"eu": "llmd-poc-eu", "us": "llmd-poc-us"}
PF_PORT = {"eu": 18001, "us": 18002}
REPO = subprocess.run(["git", "-C", sys.path[0], "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip()
OUT = sys.argv[1] if len(sys.argv) > 1 else f"{REPO}/docs/results/p5/t6-prefix-cache.jsonl"

def sh(cmd, check=True):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd}\n{r.stderr.strip()}")
    return r.stdout.strip()

def apply_policy(region):
    sh("export DOCKER_CONFIG=$(mktemp -d) && echo '{}' > $DOCKER_CONFIG/config.json && "
       f"helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 "
       f"--kube-context llmd-poc-us --namespace llmd-serving "
       f"-f {REPO}/k8s/hub/router-values.force-{region}.yaml >/dev/null")
    sh("kubectl --context llmd-poc-us -n llmd-serving rollout status deploy/llmd-hub-epp --timeout=180s")
    time.sleep(5)  # settle: avoid the rollout-race transient in measurements

def start_pf(region):
    p = subprocess.Popen(["kubectl", "--context", CTX[region], "-n", "llmd-serving",
                          "port-forward", "deploy/llmd-vllm", f"{PF_PORT[region]}:8000"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    return p

def counters(region):
    out = urllib.request.urlopen(f"http://localhost:{PF_PORT[region]}/metrics", timeout=10).read().decode()
    vals = {}
    for line in out.splitlines():
        if line.startswith("vllm:prefix_cache_hits_total"):
            vals["hits"] = float(line.rsplit(" ", 1)[1])
        elif line.startswith("vllm:prefix_cache_queries_total"):
            vals["queries"] = float(line.rsplit(" ", 1)[1])
    return vals

def make_prefix(nonce, target_words=2400):
    para = (f"[doc {nonce}] The operations handbook describes a distributed inference "
            "system with regional gateways, hub scheduling, prefix-cache-aware routing, "
            "and measured failure recovery. Each component emits correlated telemetry. ")
    words = para.split()
    return " ".join(words * (target_words // len(words) + 1))

def send(suffix, prefix, region="us"):
    body = json.dumps({"model": MODEL_BY_REGION[region], "max_tokens": 8, "stream": True,
                       "messages": [{"role": "system", "content": prefix},
                                    {"role": "user", "content": suffix}]}).encode()
    req = urllib.request.Request(f"http://{HUB}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    resp = urllib.request.urlopen(req, timeout=180)
    ttft = None
    for chunk in resp:  # first streamed chunk marks TTFT
        if chunk.strip():
            ttft = time.time() - t0
            break
    total = time.time() - t0
    hdrs = dict(resp.headers)
    return ttft, total, hdrs

def main():
    nonce = hex(int(time.time()))[2:]
    records = []
    for region in ("eu", "us"):
        apply_policy(region)
        # Env B-hybrid (GPUS_ALL_REGIONS=1): real vLLM only in US. EU requests go
        # to sims — a cold-reference with sim semantics, no real cache counters.
        pf = start_pf(region) if region == "us" else None
        try:
            prefix = make_prefix(f"{nonce}-{region}")
            c0 = counters(region) if pf else None
            ttft_cold, total_cold, h = send("Summarize the handbook in one word.", prefix, region)
            time.sleep(1)
            c1 = counters(region) if pf else None
            ttft_warm, total_warm, h2 = send("Now say just 'done'.", prefix, region)
            time.sleep(1)
            c2 = counters(region) if pf else None
            records.append({
                "region": region,
                "serving": "vllm" if pf else "sim (cold-reference)",
                "pod": h2.get("x-inference-pod", h.get("x-inference-pod")),
                "prefix_words": len(prefix.split()),
                "cold": {"ttft_s": round(ttft_cold, 3), "total_s": round(total_cold, 3)},
                "warm": {"ttft_s": round(ttft_warm, 3), "total_s": round(total_warm, 3),
                         "ttft_ratio": round(ttft_warm / ttft_cold, 3) if ttft_cold else None},
                "counters_before": c0, "counters_mid": c1, "counters_after": c2,
                "hits_delta": (c2.get("hits", 0) - c0.get("hits", 0)) if pf else None,
                "queries_delta": (c2.get("queries", 0) - c0.get("queries", 0)) if pf else None,
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })
        finally:
            if pf:
                pf.terminate()
    with open(OUT, "a") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")
    print(json.dumps(records, indent=1))

if __name__ == "__main__":
    main()
