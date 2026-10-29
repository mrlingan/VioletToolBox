"""Loopback fixtures only. No external services or Android devices are used."""
import http.server
import json
import pathlib
import sys
import time
import urllib.parse

BODY = bytes(range(256)) * 4096


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_json(self, value):
        encoded = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parsed.query)
        path = parsed.path
        if path.startswith("/rom/"):
            if not query.get("brand") or not query.get("packageType"):
                self.send_error(400)
            elif path.endswith("/series"):
                self.send_json({"items": [" 系列 A ", "系列 A", "系列 B"]})
            elif path.endswith("/devices") and query.get("series") == ["系列 A"]:
                self.send_json({"items": ["测试机型"]})
            elif path.endswith("/versions") and query.get("device") == ["测试机型"]:
                self.send_json({"items": [{"name": "测试版本"}, {"name": "测试版本"}]})
            else:
                self.send_error(400)
            return
        if path == "/error":
            self.send_error(403)
            return
        if path == "/with-header" and self.headers.get("Referer") != "https://example.invalid/firmware":
            self.send_error(403)
            return
        if path == "/oversize":
            self.send_response(200)
            self.send_header("Content-Length", str(10 * 1024 * 1024))
            self.end_headers()
            self.close_connection = True
            return
        start = 0
        ranged = self.headers.get("Range") is not None and path != "/ignore"
        if ranged:
            start = int(self.headers["Range"].split("=")[1].split("-")[0])
            if self.headers.get("If-Range") != '"fixture-v1"':
                self.send_error(400)
                return
            if start == len(BODY):
                self.send_response(416)
                self.send_header("ETag", '"fixture-v1"')
                self.send_header("Content-Range", f"bytes */{len(BODY)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        if path == "/wrong":
            start = 0
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(BODY) - start))
        self.send_header("Connection", "close")
        if path != "/novalidator":
            self.send_header("ETag", '"fixture-v2"' if path == "/changed" else '"fixture-v1"')
        if ranged:
            self.send_header("Content-Range", f"bytes {start}-{len(BODY) - 1}/{len(BODY)}")
        self.end_headers()
        end = len(BODY) // 2 if path == "/short" else len(BODY)
        try:
            for offset in range(start, end, 4096):
                self.wfile.write(BODY[offset:min(offset + 4096, end)])
                self.wfile.flush()
                if path == "/slow":
                    time.sleep(0.015)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def do_POST(self):
        if self.path != "/rom/download-link":
            self.send_error(404)
            return
        value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if value != {"packageType": "full", "brand": "OnePlus", "series": "系列 A", "device": "测试机型", "version": "测试版本"}:
            self.send_error(400)
            return
        url = f"http://127.0.0.1:{self.server.server_port}/with-header"
        self.send_json({"links": [url, "javascript:alert(1)", url + "?mirror=1"],
                        "linkOptions": [{"label": "主地址", "url": url, "isPrimary": True}],
                        "requestHeaders": {"Referer": "https://example.invalid/firmware"}})


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
