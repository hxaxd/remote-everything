import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import time


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


class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address


if sys.argv[1] == "--stop-child":
    child = subprocess.Popen([sys.executable, __file__, sys.argv[2]])
    deadline = time.monotonic() + 5
    while True:
        try:
            with socket.create_connection(("127.0.0.1", int(sys.argv[2])), timeout=0.1):
                break
        except OSError:
            if time.monotonic() >= deadline:
                child.kill()
                raise RuntimeError("stop helper child did not start")
            time.sleep(0.01)
    with open(sys.argv[3], "w", encoding="ascii") as output:
        output.write(str(child.pid))
    sys.exit(0)

if sys.argv[1] == "--launch-child":
    child = subprocess.Popen([sys.executable, __file__, sys.argv[2]])
    with open(sys.argv[3], "w", encoding="ascii") as output:
        output.write(str(child.pid))
    os._exit(0)

if len(sys.argv) == 5 and sys.argv[2] == "--with-child":
    subprocess.Popen([sys.executable, __file__, sys.argv[3]])
    with open(sys.argv[4], "w", encoding="ascii") as output:
        output.write(str(os.getpgrp()))

Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
