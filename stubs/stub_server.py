#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""STUB_MODE 桩服务：零依赖模拟上游服务，用于首版构建与冒烟测试。

用法: python3 stub_server.py <port> <svc-name>
端点:
  /            HTML 首页（故意含绝对路径 /api、/ws、/static 引用，用于验证 sub_filter）
  /app.js      JS（含 "/api/"、"/ws/" 字符串）
  /static/style.css
  /api/status  JSON
  /api/stream  SSE 流（5 个 chunk，间隔 0.5s —— 验证 proxy_buffering off）
  /ws          WebSocket echo（标准握手 —— 验证 Upgrade 链路）
"""
import base64
import hashlib
import json
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
SVC = sys.argv[2] if len(sys.argv) > 2 else "stub"
WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

INDEX = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>{SVC} stub</title>
<link rel="stylesheet" href="/static/style.css">
<script src="/app.js"></script>
</head><body>
<h1>{SVC} stub service</h1>
<p>如果你通过子路径访问且本页样式/脚本正常，说明 sub_filter 改写生效。</p>
<div id="status">loading...</div>
<script>
fetch('/api/status').then(r => r.json()).then(d => {{
  document.getElementById('status').textContent = 'api: ' + d.svc + ' ok';
}});
var es = new EventSource('/api/stream');
var ws = new WebSocket('ws://' + location.host + '/ws');
</script>
</body></html>
"""

APP_JS = """// stub app.js —— 故意使用绝对路径，验证 sub_filter 第二层/第四层改写
fetch("/api/status").then(function(r){ return r.json(); });
var ws = new WebSocket("ws://" + location.host + "/ws/echo");
location.href = "/dashboard";
"""

CSS = "body { font-family: sans-serif; margin: 2em; } h1 { color: #1f4e79; }"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stdout.write("[stub:%s] %s\n" % (SVC, fmt % args))
        sys.stdout.flush()

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"
        if path == "/":
            self._send(200, INDEX)
        elif path == "/app.js":
            self._send(200, APP_JS, "text/javascript; charset=utf-8")
        elif path == "/static/style.css":
            self._send(200, CSS, "text/css; charset=utf-8")
        elif path == "/api/status":
            self._send(200, json.dumps({"svc": SVC, "ok": True, "ts": time.time()}),
                       "application/json")
        elif path == "/api/stream":
            self._sse()
        elif path in ("/ws", "/ws/echo"):
            self._websocket()
        elif path == "/dashboard":
            self._send(200, "<h1>dashboard</h1>")
        else:
            self._send(404, "not found", "text/plain")

    def _sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        for i in range(5):
            self.wfile.write(("data: chunk-%d\n\n" % i).encode())
            self.wfile.flush()
            time.sleep(0.5)

    def _websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self._send(400, "bad request", "text/plain")
            return
        accept = base64.b64encode(
            hashlib.sha1((key + WS_MAGIC).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        # echo 一帧文本帧即可满足握手验证
        try:
            head = self.rfile.read(2)
            if len(head) == 2:
                length = head[1] & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4)
                payload = bytearray(self.rfile.read(length))
                for i in range(len(payload)):
                    payload[i] ^= mask[i % 4]
                frame = bytes([0x81])
                n = len(payload)
                if n < 126:
                    frame += bytes([n])
                elif n < 65536:
                    frame += bytes([126]) + struct.pack(">H", n)
                else:
                    frame += bytes([127]) + struct.pack(">Q", n)
                self.wfile.write(frame + bytes(payload))
                self.wfile.flush()
        except Exception:
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("[stub:%s] listening on 127.0.0.1:%d" % (SVC, PORT), flush=True)
    server.serve_forever()
