#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""certbot manual hook: DNSPod（腾讯云 DNS）DNS-01 挑战。

用法: dnspod.py auth|cleanup
环境:
  DNSPOD_TOKEN   必填，格式 "ID,TOKEN"（DNSPod 控制台 → API 密钥）
  CERTBOT_DOMAIN / CERTBOT_VALIDATION  由 certbot 注入
  DNS_PROPAGATION_SECONDS  可选，默认 40
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = "https://dnsapi.cn"
TOKEN = os.environ.get("DNSPOD_TOKEN", "")
DOMAIN = os.environ.get("CERTBOT_DOMAIN", "")
VALIDATION = os.environ.get("CERTBOT_VALIDATION", "")


def api(path, **params):
    params.update({"login_token": TOKEN, "format": "json"})
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(f"{API}/{path}", data=data)
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.load(resp)
    status = payload.get("status", {})
    if status.get("code") not in ("1", "8"):  # 8 = 记录已存在类提示
        raise RuntimeError(f"DNSPod {path} 失败: {status.get('message')}")
    return payload


def find_main_domain():
    """在账号域名列表中找 CERTBOT_DOMAIN 的最长后缀（主域）。"""
    payload = api("Domain.List")
    names = [d["name"] for d in payload.get("domains", [])]
    matches = [n for n in names if DOMAIN == n or DOMAIN.endswith("." + n)]
    if not matches:
        raise RuntimeError(f"DNSPod 账号下未找到 {DOMAIN} 的主域")
    return max(matches, key=len)


def sub_domain(main):
    prefix = DOMAIN[: -len(main)].rstrip(".")
    return "_acme-challenge" if not prefix else f"_acme-challenge.{prefix}"


def main():
    if not TOKEN or not DOMAIN:
        sys.exit("[dnspod] 缺 DNSPOD_TOKEN 或 CERTBOT_DOMAIN")
    action = sys.argv[1] if len(sys.argv) > 1 else "auth"
    root = find_main_domain()
    sub = sub_domain(root)

    if action == "auth":
        payload = api("Record.Create", domain=root,
                      sub_domain=sub, record_type="TXT",
                      record_line="默认", value=VALIDATION)
        rid = payload.get("record", {}).get("id")
        print(f"[dnspod] TXT 已创建: {sub}.{root} (id={rid})", flush=True)
        wait = int(os.environ.get("DNS_PROPAGATION_SECONDS", "40"))
        print(f"[dnspod] 等待解析生效 {wait}s ...", flush=True)
        time.sleep(wait)
    else:
        payload = api("Record.List", domain=root, sub_domain=sub)
        for rec in payload.get("records", []):
            if rec.get("type") == "TXT" and rec.get("value") == VALIDATION:
                api("Record.Remove", domain=root, record_id=rec["id"])
                print(f"[dnspod] TXT 已删除: id={rec['id']}", flush=True)


if __name__ == "__main__":
    main()
