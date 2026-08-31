#!/usr/bin/env python3
import base64, json, os, subprocess, sys, urllib.request, urllib.error

REPO = "yuanshandalishuishou/deepseek-harness-zulin"
BASE = os.path.dirname(os.path.abspath(__file__))
TOKEN = subprocess.check_output(["git", "remote", "get-url", "origin"], cwd=BASE).decode().strip()
TOKEN = TOKEN.split("x-access-token:")[1].split("@")[0]
HEADERS = {"Authorization": "Bearer %s" % TOKEN, "Accept": "application/vnd.github+json",
           "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "workbuddy-sync"}

def api(method, path):
    url = "https://api.github.com/repos/%s/%s" % (REPO, path)
    req = urllib.request.Request(url, headers=HEADERS, method=method)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))

# my edited files (uncommitted)
EDITED = {"Dockerfile", "README.md", "deploy.sh", "用户需求.md", "技术方案.md"}

# remote tree recursive
tree = api("GET", "git/trees/%s?recursive=1" % sys.argv[1])
remote_files = {}
for e in tree.get("tree", []):
    if e["type"] == "blob":
        remote_files[e["path"]] = e["sha"]

print("REMOTE files:", len(remote_files))
diffs = []
for path, rsha in sorted(remote_files.items()):
    lpath = os.path.join(BASE, path)
    if os.path.exists(lpath) and os.path.isfile(lpath):
        lsha = subprocess.check_output(["git", "hash-object", lpath], cwd=BASE).decode().strip()
    else:
        lsha = "(absent locally)"
    if lsha != rsha:
        diffs.append((path, rsha[:10], lsha[:10] if isinstance(lsha, str) else lsha, path in EDITED))

print("\n=== FILES DIFFERENT between REMOTE HEAD and LOCAL WORKING TREE ===")
for path, r, l, edited in diffs:
    tag = "  <-- MY EDIT" if edited else "  <-- NOT my edit (would be reverted if I push local over remote)"
    print(f"  {path:40s} remote={r} local={l}{tag}")
print("\nTotal differing:", len(diffs), "| my-edited among them:", sum(1 for d in diffs if d[3]))
