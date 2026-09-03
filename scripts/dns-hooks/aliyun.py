#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""certbot manual hook: 阿里云云解析 DNS-01 挑战（RPC 签名直连，无 SDK 依赖）。

用法: aliyun.py auth|cleanup
环境:
  ALIYUN_ACCESS_KEY_ID / ALIYUN_ACCESS_KEY_SECRET  必填
  CERTBOT_DOMAIN / CERTBOT_VALIDATION  由 certbot 注入
  DNS_PROPAGATION_SECONDS  可选，默认 40
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

ENDPOINT = "https://alidns.aliyuncs.com/"
AK_ID = os.environ.get("ALIYUN_ACCESS_KEY_ID", "")
AK_SECRET = os.environ.get("ALIYUN_ACCESS_KEY_SECRET", "")
DOMAIN = os.environ.get("CERTBOT_DOMAIN", "")
VALIDATION = os.environ.get("CERTBOT_VALIDATION", "")


def _encode(s):
    """阿里云 RPC 专用百分号编码（RFC3986 微调）。"""
    return (urllib.parse.quote_plus(str(s), safe="")
            .replace("+", "%20").replace("*", "%2A").replace("%7E", "~"))


def rpc(action, **params):
    common = {
        "Format": "JSON",
        "Version": "2015-01-09",
        "AccessKeyId": AK_ID,
        "SignatureMethod": "HMAC-SHA1",
        "Timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "SignatureVersion": "1.0",
        "SignatureNonce": uuid.uuid4().hex,
        "Action": action,
    }
    all_params = {**common, **params}
    canonicalized = "&".join(
        f"{_encode(k)}={_encode(all_params[k])}" for k in sorted(all_params)
    )
    string_to_sign = f"GET&{_encode('/')}&{_encode(canonicalized)}"
    digest = hmac.new((AK_SECRET + "&").encode(),
                      string_to_sign.encode(), hashlib.sha1).digest()
    signature = base64.b64encode(digest).decode()
    url = f"{ENDPOINT}?{canonicalized}&Signature={_encode(signature)}"
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.load(resp)


def find_main_domain():
    payload = rpc("DescribeDomains", PageSize=100)
    names = [d["DomainName"] for d in payload.get("Domains", {}).get("Domain", [])]
    matches = [n for n in names if DOMAIN == n or DOMAIN.endswith("." + n)]
    if not matches:
        raise RuntimeError(f"阿里云账号下未找到 {DOMAIN} 的主域")
    return max(matches, key=len)


def sub_domain(main):
    prefix = DOMAIN[: -len(main)].rstrip(".")
    return "_acme-challenge" if not prefix else f"_acme-challenge.{prefix}"


def main():
    if not AK_ID or not AK_SECRET or not DOMAIN:
        sys.exit("[aliyun] 缺 ALIYUN_ACCESS_KEY_ID/SECRET 或 CERTBOT_DOMAIN")
    action = sys.argv[1] if len(sys.argv) > 1 else "auth"
    root = find_main_domain()
    rr = sub_domain(root)

    if action == "auth":
        payload = rpc("AddDomainRecord", DomainName=root, RR=rr,
                      Type="TXT", Value=VALIDATION)
        print(f"[aliyun] TXT 已创建: {rr}.{root} (id={payload.get('RecordId')})",
              flush=True)
        wait = int(os.environ.get("DNS_PROPAGATION_SECONDS", "40"))
        print(f"[aliyun] 等待解析生效 {wait}s ...", flush=True)
        time.sleep(wait)
    else:
        payload = rpc("DescribeDomainRecords", DomainName=root,
                      RRKeyWord=rr, TypeKeyWord="TXT", PageSize=100)
        records = payload.get("DomainRecords", {}).get("Record", [])
        for rec in records:
            if rec.get("RR") == rr and rec.get("Value") == VALIDATION:
                rpc("DeleteDomainRecord", RecordId=rec["RecordId"])
                print(f"[aliyun] TXT 已删除: id={rec['RecordId']}", flush=True)


if __name__ == "__main__":
    main()
