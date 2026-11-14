#!/usr/bin/env python3
"""T7 — multi-turn conversation affinity (Env B-hybrid).

Default hub policy (pins US real). Turns grow the exact conversation history:
  T1 [sys][q1] -> T2 [sys][q1][a1][q2] -> T3 [...][a2][q3]
Then force-eu (migration: sim cold-reference), then restore default and check
the US turn is warm-again (vllm prefix-cache hits keep increasing).
Per turn: hub_region, TTFT, vllm hits/queries deltas. Output: JSONL + stdout.
"""
import json, subprocess, sys, time, urllib.request

HUB = "34.138.131.34"
MODEL = "Qwen/Qwen2.5-Coder-14B-Instruct-AWQ"
SIM_MODEL = "llmd-poc-sim"
REPO = subprocess.run(["git", "-C", sys.path[0], "rev-parse", "--show-toplevel"],
                      capture_output=True, text=True).stdout.strip()
OUT = sys.argv[1] if len(sys.argv) > 1 else f"{REPO}/docs/results/p6/t7-multiturn.jsonl"

def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{cmd}\n{r.stderr.strip()}")

def apply_policy(values):
    sh("export DOCKER_CONFIG=$(mktemp -d) && echo '{}' > $DOCKER_CONFIG/config.json && "
       f"helm upgrade -i llmd-hub oci://ghcr.io/llm-d/charts/llm-d-router-gateway --version v1.0.0 "
       f"--kube-context llmd-poc-us --namespace llmd-serving -f {REPO}/k8s/hub/{values} >/dev/null")
    sh("kubectl --context llmd-poc-us -n llmd-serving rollout status deploy/llmd-hub-epp --timeout=180s")
    time.sleep(5)

def start_pf():
    p = subprocess.Popen(["kubectl", "--context", "llmd-poc-us", "-n", "llmd-serving",
                          "port-forward", "deploy/llmd-vllm", "18002:8000"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    return p

def counters():
    out = urllib.request.urlopen("http://localhost:18002/metrics", timeout=10).read().decode()
    vals = {}
    for line in out.splitlines():
        if line.startswith("vllm:prefix_cache_hits_total"):
            vals["hits"] = float(line.rsplit(" ", 1)[1])
        elif line.startswith("vllm:prefix_cache_queries_total"):
            vals["queries"] = float(line.rsplit(" ", 1)[1])
    return vals

def send(messages, model, session_token=None):
    body = json.dumps({"model": model, "max_tokens": 24, "stream": True, "messages": messages}).encode()
    hdrs = {"Content-Type": "application/json"}
    if session_token:                      # exercise the EPP session-affinity mechanism
        hdrs["x-session-token"] = session_token
    req = urllib.request.Request(f"http://{HUB}/v1/chat/completions", data=body, headers=hdrs)
    t0 = time.time()
    resp = urllib.request.urlopen(req, timeout=180)
    ttft, text = None, []
    for chunk in resp:
        if chunk.strip():
            if ttft is None:
                ttft = time.time() - t0
            text.append(chunk)
    return ttft, time.time() - t0, dict(resp.headers), b"".join(text)

def main():
    sysmsg = ("You are a concise assistant. Context: the hub routes inference across regions; "
              "regional schedulers pick endpoints; prefix caches reward conversation locality. " * 10)
    history = [{"role": "system", "content": sysmsg}]
    turns = [("q1", "Name one benefit of prefix caching."),
             ("q2", "And one risk of cross-region failover?"),
             ("q3", "Summarize both answers in one sentence."),
             ("q4", "After migrating, do you still have my context?"),
             ("q5", "Recap the whole conversation in three words.")]
    records, token = [], None
    pf = start_pf()
    try:
        for i, (tid, q) in enumerate(turns):
            if tid == "q1":
                apply_policy("router-values.force-us.yaml")   # real counters live here
            if tid == "q4":
                apply_policy("router-values.force-eu.yaml")   # migration: sim cold-reference
            if tid == "q5":
                apply_policy("router-values.force-us.yaml")   # return: warm-again?
            c0 = counters()
            history.append({"role": "user", "content": q})
            model = MODEL   # both regions now serve the real model name
            last_err = None
            for attempt in range(6):       # tolerate post-rollout races
                try:
                    ttft, total, hdrs, raw = send(history, model, token)
                    break
                except Exception as e:
                    last_err = e
                    time.sleep(4)
            else:
                raise last_err
            time.sleep(1)
            c1 = counters()
            token = hdrs.get("x-session-token", token)
            # extract assistant text to grow the history
            text = ""
            for line in raw.decode(errors="ignore").splitlines():
                if line.startswith("data:") and '"content":' in line:
                    try:
                        text += json.loads(line[5:].strip())["choices"][0]["delta"].get("content", "")
                    except Exception:
                        pass
            history.append({"role": "assistant", "content": text or "(empty)"})
            records.append({
                "turn": tid, "policy": "force-eu" if tid == "q4" else "default",
                "hub_region": (hdrs.get("x-session-token", "") and
                               __import__("base64").b64decode(hdrs["x-session-token"]).decode().split("/")[-1]),
                "ttft_s": round(ttft, 3), "total_s": round(total, 3),
                "hits_delta": c1.get("hits", 0) - c0.get("hits", 0),
                "queries_delta": c1.get("queries", 0) - c0.get("queries", 0),
                "history_msgs": len(history),
                "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })
    finally:
        pf.terminate()
        with open(OUT, "a") as f:          # never lose records on error
            for r in records:
                f.write(json.dumps(r) + "\n")
        print(json.dumps(records, indent=1))

if __name__ == "__main__":
    main()
