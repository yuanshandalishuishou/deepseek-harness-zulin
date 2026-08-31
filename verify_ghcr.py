import json, urllib.request, urllib.error, urllib.parse, sys

REPO = "yuanshandalishuishou/deepseek-harness-zulin"
ACCEPT = ("application/vnd.docker.distribution.manifest.list.v2+json, "
          "application/vnd.oci.image.index.v1+json, "
          "application/vnd.oci.image.manifest.v1+json, "
          "application/vnd.docker.distribution.manifest.v2+json")

def ghcr_token():
    scope = "repository:%s:pull" % REPO
    url = "https://ghcr.io/token?scope=" + urllib.parse.quote(scope)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())["token"]

TOK = ghcr_token()
print("got ghcr token len=%d" % len(TOK), flush=True)

def fetch(path, accept, label):
    url = "https://ghcr.io/v2/%s%s" % (REPO, path)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOK})
    if accept:
        req.add_header("Accept", accept)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read().decode("utf-8")
        print("[OK] %s: HTTP %d len=%d" % (label, r.status, len(data)), flush=True)
        return json.loads(data), r.status
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200]
        print("[FAIL] %s: HTTP %d %s" % (label, e.code, body), flush=True)
        return None, e.code
    except Exception as e:
        print("[ERR] %s: %s" % (label, e), flush=True)
        return None, 0

def head_blob(digest, label):
    url = "https://ghcr.io/v2/%s/blobs/%s" % (REPO, digest)
    req = urllib.request.Request(url, method="HEAD", headers={"Authorization": "Bearer " + TOK})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            print("[OK] %s: HTTP %d content-length=%s" % (label, r.status, r.headers.get("Content-Length")), flush=True)
            return r.status
    except urllib.error.HTTPError as e:
        print("[FAIL] %s: HTTP %d" % (label, e.code), flush=True)
        return e.code
    except Exception as e:
        print("[ERR] %s: %s" % (label, e), flush=True)
        return 0

idx, st = fetch("/manifests/latest", ACCEPT, "1) manifest index (latest)")
if not idx:
    sys.exit(1)
amd = None
for m in idx.get("manifests", []):
    if m.get("platform", {}).get("architecture") == "amd64":
        amd = m["digest"]; break
print("   amd64 digest =", amd, flush=True)
if not amd:
    print("no amd64 manifest found"); sys.exit(1)
child, st = fetch("/manifests/%s" % amd, ACCEPT, "2) amd64 child manifest")
if not child:
    sys.exit(1)
cfg = child["config"]["digest"]
print("   config =", cfg, flush=True)
cfg_json, _ = fetch("/blobs/%s" % cfg, None, "3) config blob")
if child.get("layers"):
    l0 = child["layers"][0]["digest"]
    head_blob(l0, "4) first layer blob (HEAD)")
print("=== DANGLING TAG CHECK done: all [OK] => image genuinely pullable ===", flush=True)

if cfg_json:
    print("\n=== IMAGE CONFIG ESSENTIALS ===", flush=True)
    print("ExposedPorts:", cfg_json.get("config", {}).get("ExposedPorts"), flush=True)
    print("Entrypoint:", cfg_json.get("config", {}).get("Entrypoint"), flush=True)
    print("Cmd:", cfg_json.get("config", {}).get("Cmd"), flush=True)
    envs = cfg_json.get("config", {}).get("Env", []) or []
    want = ("ENABLE_TOKEN_FREE_GATEWAY", "TFG_PORT", "TFG_CDP_URL", "MGMT_PORT", "ROOT_PASSWORD")
    for e in envs:
        for w in want:
            if e.startswith(w + "="):
                print("Env:", e, flush=True)
                break
    print(" (total Env entries: %d)" % len(envs), flush=True)
