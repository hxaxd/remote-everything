import http.server
import json
import os
import subprocess
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"path": self.path, "cookie": self.headers.get("Cookie", "")}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if sys.argv[1] == "--launch-child":
    child = subprocess.Popen([sys.executable, __file__, sys.argv[2]])
    with open(sys.argv[3], "w", encoding="ascii") as output:
        output.write(str(child.pid))
    os._exit(0)

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
