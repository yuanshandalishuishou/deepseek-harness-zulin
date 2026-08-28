#!/usr/bin/env python3
# =============================================================================
# DeepSeek Harness 管理端口 (默认 16688)
# -----------------------------------------------------------------------------
# 功能：
#   1) 首次启动随机生成管理员用户名 + 密码（写入 /root/.dsh/MGMT_CREDENTIALS.txt
#      与容器日志），强制要求登录后立即修改密码。
#   2) 登录后可在线修改：
#        - OpenClaw：网关令牌、默认模型、备用模型、DeepSeek API Key
#        - Hermes   ：默认模型、provider、DeepSeek API Key
#      并直接写入对应配置文件；支持一键重启 OpenClaw / Hermes 使配置生效。
# 依赖：仅标准库 + PyYAML（hermes venv 已含）。无外部网络依赖。
# =============================================================================
import json
import os
import re
import sys
import time
import hashlib
import secrets
import subprocess
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

try:
    import yaml
except Exception as e:  # pragma: no cover
    print("[MGMT] 缺少 PyYAML：%s" % e, flush=True)
    raise

MGMT_DIR = "/opt/mgmt"
USERS_FILE = os.path.join(MGMT_DIR, "users.json")
SESS_FILE = os.path.join(MGMT_DIR, "sessions.json")
CRED_FILE = "/root/.dsh/MGMT_CREDENTIALS.txt"

OPENCLAW_JSON = "/root/.openclaw/openclaw.json"
OPENCLAW_TOKEN = "/root/.openclaw/gateway_token"
OPENCLAW_ENV = "/root/.openclaw/.env"
HERMES_YAML = "/root/.hermes/config.yaml"
HERMES_ENV = "/root/.hermes/.env"

MGMT_PORT = int(os.environ.get("MGMT_PORT", "16688"))
TFG_PORT = int(os.environ.get("TFG_PORT", "3456"))

lock = threading.Lock()
sessions = {}  # token -> {"user": username, "exp": ts}


# ----------------------------- 密码哈希 --------------------------------------
def hash_password(pw):
    salt = secrets.token_bytes(16)
    d = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 200000)
    return "pbkdf2$" + salt.hex() + "$" + d.hex()


def verify_password(pw, stored):
    try:
        _, salt, d = stored.split("$")
        sd = bytes.fromhex(salt)
        dd = bytes.fromhex(d)
        return hashlib.pbkdf2_hmac("sha256", pw.encode(), sd, 200000) == dd
    except Exception:
        return False


# ----------------------------- 用户引导 --------------------------------------
def load_users():
    if not os.path.exists(USERS_FILE):
        return None
    with open(USERS_FILE) as f:
        return json.load(f)


def save_users(u):
    with open(USERS_FILE, "w") as f:
        json.dump(u, f)


def ensure_bootstrapped():
    with lock:
        if os.path.exists(USERS_FILE):
            return
        uname = "admin-" + secrets.token_hex(2)
        pw = secrets.token_urlsafe(12)
        users = {
            "username": uname,
            "password_hash": hash_password(pw),
            "must_change": True,
            "ever_logged_in": False,
            "initial_password": pw,
        }
        save_users(users)
        cred = (
            "管理端口 %d 首次登录凭据\n" % MGMT_PORT
            + "用户名: %s\n" % uname
            + "密码:   %s\n" % pw
            + "请登录后立即修改密码。\n"
        )
        try:
            os.makedirs(os.path.dirname(CRED_FILE), exist_ok=True)
            with open(CRED_FILE, "w") as f:
                f.write(cred)
        except Exception:
            pass
        print(
            "[MGMT] 首次凭据 username=%s password=%s (已写入 %s)"
            % (uname, pw, CRED_FILE),
            flush=True,
        )


# ----------------------------- 会话 ------------------------------------------
def new_session(username):
    token = secrets.token_hex(32)
    sessions[token] = {"user": username, "exp": time.time() + 3600 * 24}
    return token


def get_session(token):
    s = sessions.get(token)
    if not s:
        return None
    if s["exp"] < time.time():
        sessions.pop(token, None)
        return None
    return s


# ----------------------------- 配置读写 --------------------------------------
def read_file_trim(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return ""


def read_env(path, key):
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith(key + "="):
                return line[len(key) + 1 :].strip().strip('"').strip("'")
    except Exception:
        return ""
    return ""


def write_env(path, key, val):
    lines = []
    found = False
    if os.path.exists(path):
        for line in open(path):
            if line.strip().startswith(key + "="):
                lines.append("%s=%s\n" % (key, val))
                found = True
            else:
                lines.append(line if line.endswith("\n") else line + "\n")
    if not found:
        lines.append("%s=%s\n" % (key, val))
    with open(path, "w") as f:
        f.writelines(lines)


def read_config():
    cfg = {"openclaw": {}, "hermes": {}}
    try:
        with open(OPENCLAW_JSON) as f:
            oc = json.load(f)
        m = oc.get("agents", {}).get("defaults", {}).get("model", {})
        cfg["openclaw"]["model_primary"] = m.get("primary", "")
        fb = m.get("fallbacks", [])
        cfg["openclaw"]["model_fallback"] = fb[0] if fb else ""
    except Exception:
        pass
    cfg["openclaw"]["gateway_token"] = read_file_trim(OPENCLAW_TOKEN)
    cfg["openclaw"]["api_key"] = read_env(OPENCLAW_ENV, "DEEPSEEK_API_KEY")

    try:
        with open(HERMES_YAML) as f:
            hy = yaml.safe_load(f) or {}
        mo = hy.get("model", {}) or {}
        cfg["hermes"]["model_default"] = mo.get("default", "")
        cfg["hermes"]["model_provider"] = mo.get("provider", "")
    except Exception:
        pass
    cfg["hermes"]["api_key"] = read_env(HERMES_ENV, "DEEPSEEK_API_KEY")
    return cfg


def write_config(data):
    # ----- OpenClaw -----
    try:
        oc = {}
        if os.path.exists(OPENCLAW_JSON):
            with open(OPENCLAW_JSON) as f:
                oc = json.load(f)
        oc.setdefault("agents", {}).setdefault("defaults", {})["model"] = {
            "primary": data.get("oc_model_primary", ""),
            "fallbacks": [x for x in [data.get("oc_model_fallback", "")] if x],
        }
        oc.setdefault("gateway", {"mode": "local", "port": 18789})
        with open(OPENCLAW_JSON, "w") as f:
            json.dump(oc, f, indent=2)
    except Exception as e:
        return "openclaw json 写入失败: %s" % e
    if data.get("oc_gateway_token"):
        with open(OPENCLAW_TOKEN, "w") as f:
            f.write(data["oc_gateway_token"])
    if "oc_api_key" in data:
        write_env(OPENCLAW_ENV, "DEEPSEEK_API_KEY", data["oc_api_key"])

    # ----- Hermes -----
    try:
        hy = {}
        if os.path.exists(HERMES_YAML):
            with open(HERMES_YAML) as f:
                hy = yaml.safe_load(f) or {}
        hy.setdefault("model", {})["default"] = data.get("hermes_model_default", "")
        hy.setdefault("model", {})["provider"] = data.get("hermes_model_provider", "")
        with open(HERMES_YAML, "w") as f:
            yaml.safe_dump(
                hy, f, default_flow_style=False, allow_unicode=True, sort_keys=False
            )
    except Exception as e:
        return "hermes yaml 写入失败: %s" % e
    if "hermes_api_key" in data:
        write_env(HERMES_ENV, "DEEPSEEK_API_KEY", data["hermes_api_key"])
    return "ok"


# ----------------------------- 服务重启 --------------------------------------
def restart_openclaw():
    subprocess.run("pkill -f 'openclaw gateway' 2>/dev/null", shell=True)
    time.sleep(1)
    token = read_file_trim(OPENCLAW_TOKEN) or "openclaw-default-token"
    env = dict(os.environ)
    env["PATH"] = "/opt/node24/bin:" + env.get("PATH", "")
    env["OPENCLAW_GATEWAY_TOKEN"] = token
    with open("/var/log/openclaw.log", "a") as log:
        subprocess.Popen(
            ["openclaw", "gateway", "--port", "18789", "--bind", "lan"],
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
            cwd="/root/.openclaw",
        )
    return "openclaw 网关已重启"


def restart_hermes():
    env = dict(os.environ)
    # Web UI
    subprocess.run("pkill -f 'hermes-web-ui' 2>/dev/null", shell=True)
    time.sleep(1)
    env["AUTH_TOKEN"] = os.environ.get("HERMES_WEBUI_TOKEN", "hermes-webui-default")
    env["BIND_HOST"] = "0.0.0.0"
    with open("/var/log/hermes-webui.log", "a") as log:
        subprocess.Popen(
            ["hermes-web-ui", "start", "--port", "3000"],
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
        )
    # Dashboard
    subprocess.run("pkill -f 'hermes dashboard' 2>/dev/null", shell=True)
    time.sleep(1)
    env["HERMES_DASHBOARD_BASIC_AUTH_USERNAME"] = os.environ.get(
        "HERMES_DASHBOARD_BASIC_AUTH_USERNAME", "admin"
    )
    env["HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH"] = os.environ.get(
        "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH",
        "scrypt$16384$8$1$atn9dAPGLudawkpjmIJUkw==$SUY+40pyRdC3Tlvre8KVidhdBqtxr71GonlYgpAzY3c=",
    )
    with open("/var/log/hermes.log", "a") as log:
        subprocess.Popen(
            ["hermes", "dashboard", "--port", "8080", "--host", "0.0.0.0", "--no-open"],
            stdout=log,
            stderr=subprocess.STDOUT,
            env=env,
        )
    return "hermes web-ui 与管理面板已重启"


# ----------------------------- Token-Free Gateway 状态 / 应用 --------------------------------------
def read_tfg_status():
    """探测本地 Token-Free Gateway 的健康端点 /health，并读取已授权 provider 列表。"""
    out = {"ok": False, "authorized": []}
    # 已授权 provider（来自 auth-profiles.json，即 dsh-tfg-auth 数据卷）
    try:
        ap = os.path.join(os.path.expanduser("~"), ".token-free-gateway", "auth-profiles.json")
        if os.path.exists(ap):
            with open(ap) as f:
                store = json.load(f)
            out["authorized"] = list((store.get("profiles") or {}).keys())
    except Exception:
        pass
    try:
        req = urllib.request.Request("http://127.0.0.1:%d/health" % TFG_PORT)
        with urllib.request.urlopen(req, timeout=3) as r:
            data = json.loads(r.read().decode("utf-8"))
        out.update({
            "ok": True,
            "status": data.get("status"),
            "browser": data.get("browser"),
            "providers": data.get("providers"),
            "models": data.get("models"),
        })
    except Exception as e:
        out["error"] = str(e)
    return out


def apply_tfg(target, model):
    """把 Token-Free Gateway 作为 OpenAI 兼容 provider 写入 OpenClaw / Hermes 配置并热重载。"""
    model = (model or "").strip()
    if not model:
        return "模型 ID 不能为空"
    if target == "openclaw":
        try:
            oc = {}
            if os.path.exists(OPENCLAW_JSON):
                with open(OPENCLAW_JSON) as f:
                    oc = json.load(f)
            oc.setdefault("models", {}).setdefault("providers", {})["tokenfree"] = {
                "baseUrl": "http://localhost:%d/v1" % TFG_PORT,
                "apiKey": "",
            }
            oc.setdefault("agents", {}).setdefault("defaults", {})["model"] = {
                "primary": "tokenfree/%s" % model,
                "fallbacks": ["tokenfree/%s" % model],
            }
            with open(OPENCLAW_JSON, "w") as f:
                json.dump(oc, f, indent=2)
        except Exception as e:
            return "openclaw 写入失败: %s" % e
        restart_openclaw()
        return "已写入 OpenClaw：model.primary=tokenfree/%s，并已重载网关" % model
    elif target == "hermes":
        try:
            hy = {}
            if os.path.exists(HERMES_YAML):
                with open(HERMES_YAML) as f:
                    hy = yaml.safe_load(f) or {}
            hy.setdefault("providers", {})["tokenfree"] = [{
                "label": "TOKEN_FREE_GATEWAY",
                "auth_type": "api_key",
                "source": "env:DEEPSEEK_API_KEY",
                "base_url": "http://localhost:%d/v1" % TFG_PORT,
            }]
            hy.setdefault("model", {})["provider"] = "tokenfree"
            hy["model"]["default"] = model
            with open(HERMES_YAML, "w") as f:
                yaml.safe_dump(hy, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
        except Exception as e:
            return "hermes 写入失败: %s" % e
        restart_hermes()
        return "已写入 Hermes：provider=tokenfree / default=%s，并已重载服务" % model
    return "未知目标: %s" % target


# ----------------------------- Token-Free Gateway 一键捕获 --------------------------------------
TFG_CAPTURE_TS = "/opt/token-free-gateway/src/cli/tfg-capture.ts"


def tfg_webauth():
    """一键在容器内触发 webauth 捕获：遍历已登录 provider 并写入 auth-profiles.json。"""
    # 前置检查：RDP 桌面中的「有头」Chrome（CDP 9222）必须在线
    try:
        with urllib.request.urlopen("http://127.0.0.1:9222/json/version", timeout=3) as r:
            if r.status != 200:
                raise Exception("bad status")
    except Exception:
        return {
            "ok": False,
            "msg": "未检测到 RDP 桌面中的 Chrome（CDP 9222 未监听）。请先通过 xRDP 远程桌面"
                   "（宿主机 IP:13389，用户 root）登录各 AI 网站，再点击「一键捕获」。",
        }
    # 运行非交互式捕获脚本（bun）
    env = dict(os.environ)
    env["PATH"] = "/root/.bun/bin:" + env.get("PATH", "")
    try:
        out = subprocess.run(
            ["/root/.bun/bin/bun", TFG_CAPTURE_TS],
            capture_output=True, text=True, timeout=400, env=env,
        )
        raw = (out.stdout or "") + (out.stderr or "")
    except subprocess.TimeoutExpired as e:
        raw = (e.stdout or b"") + (e.stderr or b"")
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        return {"ok": False, "msg": "捕获超时（>400s），请重试或分批捕获", "log": raw}
    except Exception as e:
        return {"ok": False, "msg": "捕获脚本执行失败: %s" % e}
    summary = {}
    for line in raw.splitlines():
        if line.startswith("SUMMARY_JSON:"):
            try:
                summary = json.loads(line[len("SUMMARY_JSON:"):])
            except Exception:
                pass
    ok = sum(1 for v in summary.values() if v == "ok")
    return {
        "ok": True,
        "msg": "捕获完成：%d/%d 家成功" % (ok, len(summary)),
        "log": raw,
        "summary": summary,
    }


# ----------------------------- 角色设定 (Role) --------------------------------------
ROLE_SCRIPTS_DIR = "/opt/role-scripts"
ROLE_HARNESS = os.path.join(ROLE_SCRIPTS_DIR, "deepseekharness_role.sh")
ROLE_OPENCLAW = os.path.join(ROLE_SCRIPTS_DIR, "openclaw_role.sh")
DASH_SOULS = "/opt/dsh-initial/souls"


def list_roles():
    """列出可用人设：DeepSeek Harness 取镜像自带 souls 目录；OpenClaw 为镜像默认工作区角色。"""
    harness = []
    try:
        for f in sorted(os.listdir(DASH_SOULS)):
            if f.endswith(".md"):
                harness.append(f[:-3])
    except Exception:
        pass
    if not harness:
        harness = ["enterprise-boss"]
    return {"harness": harness, "openclaw": ["default"]}


def apply_role(target, persona):
    """一键应用角色脚本：harness 改 persona；openclaw 同步工作区角色文件。

    - harness 的 dsh web 是容器 PID 1，无法在容器内热重启，故仅写入配置并提示重启容器；
    - openclaw 网关可安全热重启，应用后自动重载使其生效。
    """
    persona = (persona or "enterprise-boss").strip()
    if target == "harness":
        script, args = ROLE_HARNESS, [persona]
    elif target == "openclaw":
        script, args = ROLE_OPENCLAW, []
    else:
        return {"ok": False, "msg": "未知目标: %s" % target}
    if not os.path.exists(script):
        return {"ok": False, "msg": "角色脚本不存在: %s（请确认镜像已带 role-scripts）" % script}
    env = dict(os.environ)
    env["PATH"] = "/usr/local/bin:/bin:/usr/bin:" + env.get("PATH", "")
    try:
        out = subprocess.run(
            ["bash", script] + args, capture_output=True, text=True, timeout=120, env=env
        )
        raw = (out.stdout or "") + (out.stderr or "")
        ok = out.returncode == 0
        extra = ""
        if ok and target == "openclaw":
            restart_openclaw()
            extra = "；OpenClaw 网关已自动重载"
        elif ok and target == "harness":
            extra = "；请重启容器使角色生效：docker restart dsh-prod"
        return {
            "ok": ok,
            "msg": ("应用成功" if ok else "应用失败（返回码 %d）" % out.returncode) + extra,
            "log": raw,
        }
    except subprocess.TimeoutExpired as e:
        raw = (e.stdout or b"") + (e.stderr or b"")
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "replace")
        return {"ok": False, "msg": "应用超时（>120s）", "log": raw}
    except Exception as e:
        return {"ok": False, "msg": "执行失败: %s" % e}


# ----------------------------- HTTP 处理 -------------------------------------
PAGE = r"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DeepSeek Harness 管理</title>
<style>
  :root{--bg:#f5f7fa;--card:#fff;--bd:#e3e8ef;--tx:#1f2933;--mut:#6b7280;--pri:#2563eb;--prih:#1d4ed8;--ok:#16a34a;--warn:#d97706;--err:#dc2626}
  *{box-sizing:border-box}
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--tx);padding:24px}
  .wrap{max-width:920px;margin:0 auto}
  h1{font-size:20px;margin:0 0 4px}
  .sub{color:var(--mut);font-size:13px;margin-bottom:18px}
  .card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:18px;margin-bottom:16px}
  .card h2{font-size:15px;margin:0 0 12px;display:flex;align-items:center;gap:8px}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--pri)}
  label{display:block;font-size:13px;color:var(--mut);margin:10px 0 4px}
  input,select{width:100%;padding:9px 11px;border:1px solid var(--bd);border-radius:8px;font-size:14px;background:#fff;color:var(--tx)}
  input:focus,select:focus{outline:none;border-color:var(--pri)}
  .row{display:flex;gap:10px;align-items:center;margin-top:14px;flex-wrap:wrap}
  button{background:var(--pri);color:#fff;border:0;border-radius:8px;padding:9px 16px;font-size:14px;cursor:pointer}
  button:hover{background:var(--prih)}
  button.sec{background:#fff;color:var(--pri);border:1px solid var(--pri)}
  button.sec:hover{background:#eff4ff}
  .msg{font-size:13px;margin-top:10px;min-height:18px}
  .msg.ok{color:var(--ok)} .msg.err{color:var(--err)} .msg.warn{color:var(--warn)}
  .hint{background:#fff7ed;border:1px solid #fed7aa;color:#9a3412;padding:10px 12px;border-radius:8px;font-size:13px;margin-bottom:14px}
  .cred{font-family:ui-monospace,Menlo,Consolas,monospace;background:#0f172a;color:#e2e8f0;padding:10px 12px;border-radius:8px;white-space:pre;font-size:13px;margin-top:8px}
  .login{max-width:380px;margin:8vh auto}
  .topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}
  .who{font-size:13px;color:var(--mut)}
  .badge{display:inline-block;background:#fef3c7;color:#92400e;font-size:12px;padding:2px 8px;border-radius:6px;margin-left:8px}
  code{background:#f1f5f9;padding:1px 5px;border-radius:4px;font-size:12px}
</style>
</head>
<body>
<div class="wrap" id="app"><div style="padding:40px;color:var(--mut)">加载中…</div></div>
<script>
const api = async (m,u,b)=>{
  const o={method:m,headers:{}};
  if(b!==undefined){o.headers['Content-Type']='application/json';o.body=JSON.stringify(b);}
  const r=await fetch(u,o); const t=await r.text();
  let j=null; try{j=JSON.parse(t)}catch(e){}
  return {status:r.status,json:j,text:t};
};
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function field(id,label,val,ph){return `<label for="${id}">${label}</label><input id="${id}" value="${esc(val)}" placeholder="${ph||''}">`}

async function boot(){
  const r=await api('GET','/api/who');
  if(r.json && r.json.user){
    if(r.json.must_change) return changePw(true);
    return main();
  }
  return login();
}

async function login(){
  const b=await api('GET','/api/bootstrap');
  let cred='';
  if(b.json && b.json.shown){cred=`<div class="hint">首次登录凭据（请妥善保管，登录后将不再显示）：
    <div class="cred">用户名: ${esc(b.json.username)}\n密码:   ${esc(b.json.password)}</div></div>`;}
  document.getElementById('app').innerHTML=`<div class="card login">
    <h1>管理登录</h1><div class="sub">DeepSeek Harness 管理端口 ${''}</div>
    ${cred}
    <label>用户名</label><input id="u">
    <label>密码</label><input id="p" type="password">
    <div class="row"><button onclick="doLogin()">登录</button></div>
    <div class="msg" id="m"></div>
  </div>`;
}
async function doLogin(){
  const r=await api('POST','/api/login',{username:u.value,password:p.value});
  if(r.json&&r.json.ok){location.reload();}
  else{document.getElementById('m').className='msg err';document.getElementById('m').textContent=r.json?r.json.msg:'登录失败';}
}

async function changePw(forced){
  document.getElementById('app').innerHTML=`<div class="card login">
    <h1>修改密码${forced?'<span class="badge">首次登录必须修改</span>':''}</h1>
    <label>当前密码</label><input id="old" type="password">
    <label>新密码</label><input id="nv" type="password">
    <label>确认新密码</label><input id="nv2" type="password">
    <div class="row"><button onclick="doChange()">保存新密码</button></div>
    <div class="msg" id="m"></div></div>`;
}
async function doChange(){
  const r=await api('POST','/api/change_password',{old:old.value,new:document.getElementById('nv').value,new2:document.getElementById('nv2').value});
  if(r.json&&r.json.ok){location.reload();}
  else{document.getElementById('m').className='msg err';document.getElementById('m').textContent=r.json?r.json.msg:'修改失败';}
}

async function main(){
  const r=await api('GET','/api/config'); const c=r.json||{openclaw:{},hermes:{}};
  document.getElementById('app').innerHTML=`
  <div class="topbar"><div><h1>DeepSeek Harness 管理</h1><div class="sub">在线修改 OpenClaw / Hermes 配置并热重启服务</div></div>
    <div class="who">当前用户：<b>${esc(r.json._user||'')}</b> <button class="sec" onclick="logout()">退出</button></div></div>

  <div class="card"><h2><span class="dot"></span>OpenClaw 网关</h2>
    ${field('oc_tok','网关令牌 (OPENCLAW_GATEWAY_TOKEN)',c.openclaw.gateway_token,'openclaw-default-token')}
    ${field('oc_pri','默认模型 (model.primary)',c.openclaw.model_primary,'deepseek/deepseek-v4-pro')}
    ${field('oc_fb','备用模型 (model.fallbacks)',c.openclaw.model_fallback,'deepseek/deepseek-v4-flash')}
    ${field('oc_key','DeepSeek API Key',c.openclaw.api_key,'')}
    <div class="row"><button onclick="save('openclaw')">保存 OpenClaw 配置</button>
      <button class="sec" onclick="restart('openclaw')">重启 OpenClaw 网关</button>
      <span class="msg" id="m_oc"></span></div>
  </div>

  <div class="card"><h2><span class="dot"></span>Hermes Agent</h2>
    ${field('hz_def','默认模型 (model.default)',c.hermes.model_default,'deepseek-v4-pro')}
    ${field('hz_pro','Provider (model.provider)',c.hermes.model_provider,'deepseek')}
    ${field('hz_key','DeepSeek API Key',c.hermes.api_key,'')}
    <div class="row"><button onclick="save('hermes')">保存 Hermes 配置</button>
      <button class="sec" onclick="restart('hermes')">重启 Hermes (Web UI + 面板)</button>
      <span class="msg" id="m_hz"></span></div>
  </div>
  <div class="card tfg"><h2><span class="dot" style="background:#7c3aed"></span>Token-Free Gateway（免 Token 网关）</h2>
    <div id="tfg_status" class="msg">状态加载中…</div>
    <div class="hint">通过浏览器网页会话<b>免 API Key</b>调用 Claude / ChatGPT / DeepSeek / Qwen / Gemini / Kimi / Grok / Doubao / GLM / Perplexity 等 13 家模型，对外暴露为标准 OpenAI 兼容接口（<code>/v1/chat/completions</code>）。</div>
    <label for="tfg_model">要使用的模型 (Model ID)</label>
    <input id="tfg_model" list="tfg_models" placeholder="deepseek-chat" value="${esc(c.tfg_model||'')}">
    <datalist id="tfg_models">
      <option value="deepseek-chat"></option><option value="deepseek-reasoner"></option>
      <option value="chatgpt-4o"></option><option value="chatgpt-4o-mini"></option>
      <option value="claude-sonnet-4-20250514"></option><option value="claude-opus-4-20250514"></option>
      <option value="gemini-2.5-pro"></option><option value="qwen-max"></option>
      <option value="kimi-k2"></option><option value="grok-4"></option>
      <option value="doubao-pro"></option><option value="glm-4.5"></option>
      <option value="perplexity-sonar"></option>
    </datalist>
    <div class="hint"><b>端点（OpenAI 兼容）</b><br>容器内：<code>http://localhost:__TFG_PORT__/v1</code>（若已映射宿主机端口，例如 <code>-p 13456:3456</code>，则外部为 <code>http://&lt;宿主机IP&gt;:13456/v1</code>）<br>API Key：留空即可（网关默认不鉴权）。</div>
    <details style="margin-top:10px"><summary style="cursor:pointer;color:var(--pri)">使用步骤与说明</summary>
      <ol style="font-size:13px;color:var(--mut);line-height:1.7">
        <li>运行容器时开启：<code>-e ENABLE_TOKEN_FREE_GATEWAY=1 -p 13456:3456</code>；开启后，当你通过 xRDP 远程桌面（宿主机 IP:<code>13389</code>，用户 <code>root</code>）登录时，桌面会自动弹出有头 Chrome（CDP 9222）供你可视化登录。</li>
        <li><b>可视化授权（推荐）</b>：在 xRDP 桌面里登录各 AI 网站后，直接点击下方「一键捕获登录态」按钮，即可把已登录会话写入凭证（无需手动执行 webauth 命令、也不会卡在无头浏览器里）。</li>
        <li>授权后，在 OpenClaw / Hermes / 任意 OpenAI 兼容客户端中，把 base_url 指向 <code>http://localhost:__TFG_PORT__/v1</code>、模型填上方所选 Model ID 即可免 Token 使用。</li>
        <li>下方「应用到 OpenClaw / Hermes」按钮会自动写入对应配置并热重载。</li>
      </ol>
    </details>
    <div class="row" style="margin-top:10px">
      <button onclick="captureTfg()" style="background:#7c3aed">一键捕获登录态 (webauth)</button>
      <span class="msg" id="m_cap"></span>
    </div>
    <pre id="tfg_capture_out" style="display:none;background:#0f172a;color:#e2e8f0;padding:10px 12px;border-radius:8px;font-size:12px;max-height:260px;overflow:auto;white-space:pre-wrap;margin-top:10px"></pre>
    <div class="row"><button onclick="applyTfg('openclaw')">应用到 OpenClaw</button>
      <button onclick="applyTfg('hermes')">应用到 Hermes</button>
      <span class="msg" id="m_tfg"></span></div>
  </div>
  <div class="card role"><h2><span class="dot" style="background:#0891b2"></span>角色设定 (Role)</h2>
    <div class="hint">镜像保持「原始状态」，角色由下方脚本按需应用。DeepSeek Harness 角色修改后需<b>重启容器</b>生效；OpenClaw 角色应用后会<b>自动重载网关</b>。</div>
    <label for="role_persona">DeepSeek Harness 人设 (persona)</label>
    <select id="role_persona"><option value="enterprise-boss">enterprise-boss（纪总，八专家总协调）</option></select>
    <div class="row" style="margin-top:10px">
      <button onclick="applyRole('harness')" style="background:#0891b2">应用到 DeepSeek Harness</button>
      <button onclick="applyRole('openclaw')" style="background:#0891b2">应用到 OpenClaw</button>
      <span class="msg" id="m_role"></span>
    </div>
    <pre id="role_out" style="display:none;background:#0f172a;color:#e2e8f0;padding:10px 12px;border-radius:8px;font-size:12px;max-height:260px;overflow:auto;white-space:pre-wrap;margin-top:10px"></pre>
  </div>
  <div class="sub">提示：修改网关令牌 / API Key / 模型后，请点击对应“重启”按钮使配置生效。配置文件路径：<code>/root/.openclaw/</code> 与 <code>/root/.hermes/</code>。</div>`;
  tfgStatus();
  rolesLoad();
}
function gv(id){return document.getElementById(id).value;}
async function save(which){
  const c=which==='openclaw'?{
    oc_gateway_token:gv('oc_tok'),oc_model_primary:gv('oc_pri'),
    oc_model_fallback:gv('oc_fb'),oc_api_key:gv('oc_key')
  }:{
    hermes_model_default:gv('hz_def'),hermes_model_provider:gv('hz_pro'),
    hermes_api_key:gv('hz_key')
  };
  const r=await api('POST','/api/config',c);
  const el=document.getElementById(which==='openclaw'?'m_oc':'m_hz');
  if(r.json&&r.json.ok){el.className='msg ok';el.textContent='已保存 ✓';}
  else{el.className='msg err';el.textContent=(r.json&&r.json.msg)||'保存失败';}
}
async function restart(which){
  const el=document.getElementById(which==='openclaw'?'m_oc':'m_hz');
  el.className='msg warn';el.textContent='重启中…';
  const r=await api('POST','/api/restart',{target:which});
  if(r.json&&r.json.ok){el.className='msg ok';el.textContent=(r.json.msg||'已重启')+' ✓';}
  else{el.className='msg err';el.textContent=(r.json&&r.json.msg)||'重启失败';}
}
async function tfgStatus(){
  const r=await api('GET','/api/tfg_status');
  const el=document.getElementById('tfg_status');
  if(r.json&&r.json.ok){
    const j=r.json;
    el.className='msg '+(j.status==='ok'?'ok':'warn');
    let txt='网关状态: '+(j.status||'?')+' | 浏览器: '+(j.browser||'?')+' | 已授权: '+(j.providers||0)+' | 可用模型: '+(j.models||0);
    if(j.authorized&&j.authorized.length){txt+='\n已捕获账号: '+j.authorized.join(', ');}
    el.style.whiteSpace='pre-line';
    el.textContent=txt;
  } else {
    el.className='msg err';
    el.textContent='网关未运行（请确认已用 -e ENABLE_TOKEN_FREE_GATEWAY=1 启动，且端口 __TFG_PORT__ 已监听）';
  }
}
async function applyTfg(target){
  const m=document.getElementById('tfg_model').value.trim();
  const el=document.getElementById('m_tfg');
  if(!m){el.className='msg err';el.textContent='请先填写模型 ID';return;}
  el.className='msg warn';el.textContent='应用中…';
  const r=await api('POST','/api/tfg_apply',{target:target,model:m});
  if(r.json&&r.json.ok){el.className='msg ok';el.textContent=(r.json.msg||'已应用')+' ✓';}
  else{el.className='msg err';el.textContent=(r.json&&r.json.msg)||'应用失败';}
}
async function captureTfg(){
  const el=document.getElementById('m_cap'); const out=document.getElementById('tfg_capture_out');
  el.className='msg warn'; el.textContent='捕获中…（请确保已通过 xRDP 桌面登录各 AI 网站，约需数十秒）';
  out.style.display='block'; out.textContent='执行中…\n';
  const r=await api('POST','/api/tfg_webauth',{});
  if(r.json&&r.json.ok){ el.className='msg ok'; el.textContent=(r.json.msg||'已捕获')+' ✓'; }
  else { el.className='msg err'; el.textContent=(r.json&&r.json.msg)||'捕获失败'; }
  out.textContent=(r.json&&r.json.log)? r.json.log : (r.text||'(无输出)');
  tfgStatus();
}
async function logout(){await api('POST','/api/logout');location.reload();}
async function rolesLoad(){
  try{
    const r=await api('GET','/api/roles');
    const sel=document.getElementById('role_persona');
    if(r.json&&r.json.harness){
      const cur=sel.value||'enterprise-boss';
      sel.innerHTML=r.json.harness.map(p=>`<option value="${esc(p)}"${p===cur?' selected':''}>${esc(p)}</option>`).join('');
    }
  }catch(e){}
}
async function applyRole(target){
  const persona=document.getElementById('role_persona').value;
  const el=document.getElementById('m_role'); const out=document.getElementById('role_out');
  el.className='msg warn'; el.textContent='应用中…'; out.style.display='block'; out.textContent='执行中…\n';
  const body=target==='harness'?{target:'harness',persona:persona}:{target:'openclaw'};
  const r=await api('POST','/api/apply_role',body);
  if(r.json&&r.json.ok){el.className='msg ok';el.textContent=(r.json.msg||'已应用')+' ✓';}
  else{el.className='msg err';el.textContent=(r.json&&r.json.msg)||'应用失败';}
  out.textContent=(r.json&&r.json.log)?r.json.log:(r.text||'(无输出)');
}
boot();
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _cookie_user(self):
        ck = self.headers.get("Cookie", "")
        m = re.search(r"mgmt_session=([0-9a-f]+)", ck)
        if not m:
            return None
        return get_session(m.group(1))

    def do_GET(self):
        p = urlparse(self.path).path
        user = self._cookie_user()
        if p == "/api/who":
            if user:
                u = load_users() or {}
                self._send(200, json.dumps({"user": user["user"], "must_change": u.get("must_change", False)}))
            else:
                self._send(200, json.dumps({"user": None}))
            return
        if p == "/api/bootstrap":
            u = load_users() or {}
            shown = (not u.get("ever_logged_in", False)) and u.get("username")
            pw = ""
            if shown and u.get("initial_password"):
                pw = u["initial_password"]
            self._send(200, json.dumps({"shown": bool(shown), "username": u.get("username", ""), "password": pw}))
            return
        if p == "/api/config":
            if not user:
                self._send(401, json.dumps({"msg": "未登录"}))
                return
            cfg = read_config()
            cfg["_user"] = user["user"]
            self._send(200, json.dumps(cfg))
            return
        if p == "/api/tfg_status":
            if not user:
                self._send(401, json.dumps({"msg": "未登录"}))
                return
            self._send(200, json.dumps(read_tfg_status()))
            return
        if p == "/api/roles":
            if not user:
                self._send(401, json.dumps({"msg": "未登录"}))
                return
            self._send(200, json.dumps(list_roles()))
            return
        # 首页
        self._send(200, PAGE.replace("__TFG_PORT__", str(TFG_PORT)), "text/html; charset=utf-8")

    def do_POST(self):
        p = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0) or 0)
        raw = self.rfile.read(length) if length else b""
        data = {}
        if raw:
            try:
                data = json.loads(raw.decode("utf-8"))
            except Exception:
                data = {}
        user = self._cookie_user()

        if p == "/api/login":
            u = load_users()
            if not u or not verify_password(data.get("password", ""), u.get("password_hash", "")) or data.get("username", "") != u.get("username", ""):
                self._send(401, json.dumps({"msg": "用户名或密码错误"}))
                return
            token = new_session(u["username"])
            if not u.get("ever_logged_in", False):
                u["ever_logged_in"] = True
                u.pop("initial_password", None)
                save_users(u)
            self._send(200, json.dumps({"ok": True}), extra={"Set-Cookie": "mgmt_session=%s; HttpOnly; Path=/; SameSite=Lax; Max-Age=%d" % (token, 86400 * 24)})
            return

        if p == "/api/change_password":
            u = load_users()
            if not u or not verify_password(data.get("old", ""), u.get("password_hash", "")):
                self._send(401, json.dumps({"msg": "当前密码错误"}))
                return
            nv = data.get("new", "")
            nv2 = data.get("new2", "")
            if len(nv) < 6:
                self._send(400, json.dumps({"msg": "新密码至少 6 位"}))
                return
            if nv != nv2:
                self._send(400, json.dumps({"msg": "两次输入不一致"}))
                return
            u["password_hash"] = hash_password(nv)
            u["must_change"] = False
            save_users(u)
            self._send(200, json.dumps({"ok": True}))
            return

        if p == "/api/logout":
            if user:
                sessions.pop(self._cookie_user_token(), None)
            self._send(200, json.dumps({"ok": True}), extra={"Set-Cookie": "mgmt_session=; HttpOnly; Path=/; Max-Age=0"})
            return

        # 以下接口需登录
        if not user:
            self._send(401, json.dumps({"msg": "未登录"}))
            return

        if p == "/api/config":
            msg = write_config(data)
            if msg == "ok":
                self._send(200, json.dumps({"ok": True}))
            else:
                self._send(500, json.dumps({"ok": False, "msg": msg}))
            return

        if p == "/api/tfg_apply":
            target = data.get("target", "")
            model = data.get("model", "")
            msg = apply_tfg(target, model)
            self._send(200, json.dumps({"ok": True, "msg": msg}))
            return

        if p == "/api/tfg_webauth":
            msg = tfg_webauth()
            self._send(200, json.dumps(msg))
            return

        if p == "/api/apply_role":
            target = data.get("target", "")
            persona = data.get("persona", "")
            msg = apply_role(target, persona)
            self._send(200, json.dumps(msg))
            return

        if p == "/api/restart":
            target = data.get("target", "all")
            out = []
            try:
                if target in ("openclaw", "all"):
                    out.append(restart_openclaw())
                if target in ("hermes", "all"):
                    out.append(restart_hermes())
                self._send(200, json.dumps({"ok": True, "msg": "；".join(out)}))
            except Exception as e:
                self._send(500, json.dumps({"ok": False, "msg": str(e)}))
            return

        self._send(404, json.dumps({"msg": "not found"}))

    def _cookie_user_token(self):
        ck = self.headers.get("Cookie", "")
        m = re.search(r"mgmt_session=([0-9a-f]+)", ck)
        return m.group(1) if m else None

    def log_message(self, *a):
        pass


def main():
    ensure_bootstrapped()
    srv = ThreadingHTTPServer(("0.0.0.0", MGMT_PORT), Handler)
    print("[MGMT] 管理端口监听 0.0.0.0:%d" % MGMT_PORT, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
