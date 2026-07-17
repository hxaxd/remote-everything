#!/usr/bin/env python3
import datetime as dt
import hmac
import json
import os
import re
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 58629
CONTROL_TOKEN_FILE = "/etc/kimi-gateway/control-token"
CACHE_FILE = Path("/var/lib/kimi-control/apps-cache.json")
LOCAL_CONTROL_URL = "http://127.0.0.1:58628/__local_agent_control"
APP_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
APP_ROUTE = re.compile(r"^/__agent_remote/apps/([a-z0-9][a-z0-9._-]{0,63})/(status|start|stop)$")
OPEN_ROUTE = re.compile(r"^/__agent_remote/open/([a-z0-9][a-z0-9._-]{0,63})$")


def read_control_token() -> str:
    with open(CONTROL_TOKEN_FILE, "r", encoding="utf-8") as handle:
        return handle.read().strip()


CONTROL_TOKEN = read_control_token()


def invoke_pc(action: str, app_id: str = "") -> dict[str, object]:
    payload = json.dumps({"action": action, "id": app_id}, separators=(",", ":")).encode("utf-8")
    request = Request(
        LOCAL_CONTROL_URL,
        data=payload,
        method="POST",
        headers={
            "Authorization": f"Bearer {CONTROL_TOKEN}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urlopen(request, timeout=7) as response:
            contents = response.read(1024 * 1024).decode("utf-8")
    except (OSError, HTTPError, URLError, TimeoutError):
        return {"ok": False, "computer_connected": False, "code": "computer_offline"}
    try:
        result = json.loads(contents)
    except (json.JSONDecodeError, TypeError):
        return {"ok": False, "computer_connected": True, "code": "control_unavailable"}
    if not isinstance(result, dict):
        return {"ok": False, "computer_connected": True, "code": "control_unavailable"}
    return result


def save_apps(apps: list[object]) -> None:
    temporary = CACHE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps({"apps": apps}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    os.replace(temporary, CACHE_FILE)
    os.chmod(CACHE_FILE, 0o600)


def cached_apps() -> list[dict[str, object]]:
    try:
        value = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    apps = value.get("apps", []) if isinstance(value, dict) else []
    return [app for app in apps if isinstance(app, dict) and APP_ID.fullmatch(str(app.get("id", "")))]


def application_list() -> dict[str, object]:
    result = invoke_pc("list")
    apps = result.get("apps")
    if result.get("ok") is True and isinstance(apps, list):
        try:
            save_apps(apps)
        except OSError:
            pass
        return result
    offline = []
    for app in cached_apps():
        offline.append({
            **app,
            "computer_connected": False,
            "running": False,
            "code": "computer_offline",
        })
    return {
        "ok": True,
        "computer_connected": False,
        "code": "computer_offline",
        "apps": offline,
    }


def application_action(app_id: str, action: str) -> dict[str, object]:
    if not APP_ID.fullmatch(app_id) or action not in {"status", "start", "stop"}:
        return {"ok": False, "computer_connected": True, "code": "command_not_allowed"}
    return invoke_pc(action, app_id)


def selected_app(cookie_header: str) -> str:
    cookie = SimpleCookie()
    try:
        cookie.load(cookie_header)
    except Exception:
        return "kimi"
    value = cookie.get("AgentRemoteApp")
    if value is None or not APP_ID.fullmatch(value.value):
        return "kimi"
    return value.value


def display_state(state: dict[str, object]) -> dict[str, object]:
    code = state.get("code")
    if code == "ready":
        return {**state, "title": "远程应用正在运行", "detail": "电脑与应用都已连接。请返回手机客户端进入。", "color": "#22c55e"}
    if code == "starting":
        return {**state, "title": "远程应用正在启动", "detail": "电脑在线，应用正在后台启动，请稍候重试。", "color": "#f59e0b"}
    if code == "stopped":
        return {**state, "title": "远程应用当前未启动", "detail": "电脑在线，可在手机客户端的应用目录中启动。", "color": "#f59e0b"}
    if code == "control_unavailable":
        return {**state, "title": "电脑已连接，控制暂不可用", "detail": "安全通道在线，但控制命令暂时没有响应。", "color": "#f59e0b"}
    return {
        **state,
        "computer_connected": False,
        "code": "computer_offline",
        "title": "电脑当前未连接",
        "detail": "云端入口运行正常。电脑开机并登录 Windows 后会自动恢复。",
        "color": "#64748b",
    }


def render_page(state: dict[str, object]) -> bytes:
    shown = display_state(state)
    now = dt.datetime.now(dt.timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="color-scheme" content="dark light">
  <meta http-equiv="refresh" content="8">
  <title>{shown['title']}</title>
  <style>
    :root {{ font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color-scheme: dark; }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; min-height: 100dvh; display: grid; place-items: center; padding: 24px; background: radial-gradient(circle at top, #172554 0, #0f172a 45%, #020617 100%); color: #e2e8f0; }}
    main {{ width: min(560px, 100%); padding: 34px; border: 1px solid rgba(148,163,184,.18); border-radius: 24px; background: rgba(15,23,42,.78); box-shadow: 0 24px 80px rgba(0,0,0,.35); backdrop-filter: blur(18px); }}
    .state {{ display: flex; align-items: center; gap: 12px; color: {shown['color']}; font-weight: 650; letter-spacing: .02em; }}
    .dot {{ width: 12px; height: 12px; border-radius: 99px; background: currentColor; box-shadow: 0 0 22px currentColor; }}
    h1 {{ margin: 22px 0 12px; font-size: clamp(26px, 7vw, 38px); line-height: 1.14; color: #f8fafc; }}
    p {{ margin: 0; color: #aebbd0; line-height: 1.75; font-size: 16px; }}
    .meta {{ margin-top: 26px; padding-top: 18px; border-top: 1px solid rgba(148,163,184,.14); display: flex; justify-content: space-between; gap: 12px; color: #64748b; font-size: 13px; }}
    button {{ margin-top: 26px; width: 100%; border: 0; border-radius: 14px; padding: 14px 18px; background: #2563eb; color: white; font: inherit; font-weight: 650; cursor: pointer; }}
  </style>
</head>
<body>
  <main>
    <div class="state"><span class="dot"></span><span>Agent 远程云端入口正常</span></div>
    <h1>{shown['title']}</h1>
    <p>{shown['detail']}</p>
    <button type="button" onclick="location.reload()">立即重试</button>
    <div class="meta"><span>将在 <b id="countdown">8</b> 秒后自动重试</span><span>{now}</span></div>
  </main>
  <script>
    let left = 8;
    setInterval(() => {{ left = Math.max(0, left - 1); document.getElementById('countdown').textContent = left; }}, 1000);
  </script>
</body>
</html>"""
    return html.encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = ""
    sys_version = ""

    def authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {CONTROL_TOKEN}"
        return hmac.compare_digest(supplied, expected)

    def write_json(self, status: int, value: dict[str, object]) -> None:
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.write_common_headers("application/json; charset=utf-8", len(body))
        self.end_headers()
        self.wfile.write(body)

    def write_common_headers(self, content_type: str, length: int) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/healthz":
            self.write_json(200, {"ok": True})
            return
        if path == "/__agent_remote/apps":
            if not self.authorized():
                self.write_json(401, {"ok": False, "code": "unauthorized"})
                return
            self.write_json(200, application_list())
            return
        opened = OPEN_ROUTE.fullmatch(path)
        if opened:
            app_id = opened.group(1)
            available = {str(app.get("id")) for app in application_list().get("apps", []) if isinstance(app, dict)}
            if app_id not in available:
                self.write_json(404, {"ok": False, "code": "app_not_found"})
                return
            self.send_response(302)
            self.send_header("Location", "/")
            self.send_header("Set-Cookie", f"AgentRemoteApp={app_id}; Path=/; Max-Age=86400; Secure; HttpOnly; SameSite=Strict")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        match = APP_ROUTE.fullmatch(path)
        if match and match.group(2) == "status":
            if not self.authorized():
                self.write_json(401, {"ok": False, "code": "unauthorized"})
                return
            self.write_json(200, application_action(match.group(1), "status"))
            return
        if path == "/__kimi_remote/status":
            if not self.authorized():
                self.write_json(401, {"ok": False, "code": "unauthorized"})
                return
            self.write_json(200, application_action("kimi", "status"))
            return
        app_id = selected_app(self.headers.get("Cookie", ""))
        body = render_page(application_action(app_id, "status"))
        self.send_response(200)
        self.write_common_headers("text/html; charset=utf-8", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        match = APP_ROUTE.fullmatch(path)
        if match and match.group(2) in {"start", "stop"}:
            if not self.authorized():
                self.write_json(401, {"ok": False, "code": "unauthorized"})
                return
            self.write_json(200, application_action(match.group(1), match.group(2)))
            return
        if path in ("/__kimi_remote/start", "/__kimi_remote/stop"):
            if not self.authorized():
                self.write_json(401, {"ok": False, "code": "unauthorized"})
                return
            self.write_json(200, application_action("kimi", path.rsplit("/", 1)[-1]))
            return
        self.write_json(404, {"ok": False, "code": "not_found"})

    def log_message(self, fmt: str, *args: object) -> None:
        return


if __name__ == "__main__":
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
