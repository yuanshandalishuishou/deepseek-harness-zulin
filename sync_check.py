#!/usr/bin/env python3
import base64, json, os, subprocess, sys, urllib.request, urllib.error

REPO = "yuanshandalishuishou/deepseek-harness-zulin"
BASE = os.path.dirname(os.path.abspath(__file__))
TOKEN = subprocess.check_output(["git", "remote", "get-url", "origin"], cwd=BASE).decode().strip()
TOKEN = TOKEN.split("x-access-token:")[1].split("@")[0]

HEADERS = {
    "Authorization": "Bearer %s" % TOKEN,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "workbuddy-sync",
}

def api(method, path, data=None):
    url = "https://api.github.com/repos/%s/%s" % (REPO, path)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("HTTPError %s on %s %s: %s" % (e.code, method, path, e.read().decode("utf-8")[:800]), file=sys.stderr)
        raise

# remote main
ref = api("GET", "git/refs/heads/main")
rsha = ref["object"]["sha"]
rcommit = api("GET", "git/commits/%s" % rsha)
rtree = rcommit["tree"]["sha"]
rparents = [p["sha"] for p in rcommit.get("parents", [])]
print("REMOTE main sha :", rsha)
print("REMOTE tree     :", rtree)
print("REMOTE parents  :", rparents)
print("REMOTE message  :", rcommit.get("message", "")[:120])
print("REMOTE author   :", rcommit.get("author", {}).get("date", ""))

# local main
lsha = subprocess.check_output(["git", "rev-parse", "main"], cwd=BASE).decode().strip()
ltree = subprocess.check_output(["git", "rev-parse", "main^{tree}"], cwd=BASE).decode().strip()
print("LOCAL  main sha :", lsha)
print("LOCAL  tree     :", ltree)
print("TREES EQUAL?    :", "YES" if rtree == ltree else "NO")

# local uncommitted changes
status = subprocess.check_output(["git", "status", "--porcelain"], cwd=BASE).decode().strip()
print("---- LOCAL UNCOMMITTED ----")
print(status if status else "(none)")
