#!/usr/bin/env python3
"""Monitor GitHub Actions build run until completion, then report conclusion."""
import json, subprocess, sys, time, urllib.request, urllib.error

REPO = "yuanshandalishuishou/deepseek-harness-zulin"
RUN_ID = "33318818830"

def token():
    u = subprocess.check_output(["git", "remote", "get-url", "origin"]).decode().strip()
    return u.split("x-access-token:")[1].split("@")[0]

TOKEN = token()
H = {"Authorization": "Bearer %s" % TOKEN, "Accept": "application/vnd.github+json",
     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "wb-monitor"}

def get(path):
    req = urllib.request.Request("https://api.github.com/repos/%s/%s" % (REPO, path), headers=H)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))

deadline = time.time() + 45 * 60  # 45 min
last = ""
while time.time() < deadline:
    try:
        run = get("actions/runs/%s" % RUN_ID)
        st, concl = run["status"], run.get("conclusion")
        if (st, concl) != last:
            print("[%s] status=%s conclusion=%s" % (time.strftime("%H:%M:%S"), st, concl), flush=True)
            last = (st, concl)
        if st == "completed":
            # report job conclusions
            jobs = get("actions/runs/%s/jobs?per_page=20" % RUN_ID)
            print("=== jobs ===", flush=True)
            for j in jobs.get("jobs", []):
                print("  %s : %s" % (j["name"], j["conclusion"]), flush=True)
            print("BUILD_DONE conclusion=%s" % concl, flush=True)
            sys.exit(0)
    except Exception as e:
        print("poll err: %s" % e, flush=True)
    time.sleep(60)

print("TIMEOUT: build not finished in 45 min", flush=True)
sys.exit(2)
