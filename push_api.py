#!/usr/bin/env python3
import base64, json, os, subprocess, sys, urllib.request, urllib.error

REPO = "yuanshandalishuishou/deepseek-harness-zulin"
BASE = os.path.dirname(os.path.abspath(__file__))
TOKEN = subprocess.check_output(
    ["git", "remote", "get-url", "origin"], cwd=BASE
).decode().strip()
TOKEN = TOKEN.split("x-access-token:")[1].split("@")[0]

HEADERS = {
    "Authorization": "Bearer %s" % TOKEN,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "workbuddy-push",
}

FILES = [
    "Dockerfile",
    "entrypoint.sh",
    "mgmt/mgmt.py",
    "用户需求.md",
    "技术方案.md",
    "README.md",
]

def api(method, path, data=None):
    url = "https://api.github.com/repos/%s/%s" % (REPO, path)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("HTTPError %s on %s %s: %s" % (e.code, method, path, e.read().decode("utf-8")[:500]), file=sys.stderr)
        raise

# 1) current main commit
ref = api("GET", "git/refs/heads/main")
base_sha = ref["object"]["sha"]
print("base commit:", base_sha)

# 2) base tree
commit = api("GET", "git/commits/%s" % base_sha)
base_tree = commit["tree"]["sha"]
print("base tree:", base_tree)

# 3) create blobs
tree_entries = []
for rel in FILES:
    with open(os.path.join(BASE, rel), "rb") as f:
        content = f.read()
    blob = api("POST", "git/blobs", {
        "content": base64.b64encode(content).decode("ascii"),
        "encoding": "base64",
    })
    tree_entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
    print("blob created for", rel, "->", blob["sha"][:10])

# 4) create tree
tree = api("POST", "git/trees", {"base_tree": base_tree, "tree": tree_entries})
print("new tree:", tree["sha"])

# 5) create commit
new_commit = api("POST", "git/commits", {
    "message": "fix(tfg): 修正压缩包内二进制定位(兼容多命名/目录结构,根治构建失败)；补入 README.md",
    "tree": tree["sha"],
    "parents": [base_sha],
})
print("new commit:", new_commit["sha"])

# 6) update main ref
api("PATCH", "git/refs/heads/main", {"sha": new_commit["sha"], "force": False})
print("SUCCESS: main ->", new_commit["sha"])
print("TRIGGER: GitHub Actions 应已触发 ghcr 镜像重建")
