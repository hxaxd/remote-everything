package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	statusListenAddr = "127.0.0.1:58629"
	statusCSP        = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'"
)

var (
	statusAppID     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	statusAppRoute  = regexp.MustCompile(`^/__remote_everything/apps/([a-z0-9][a-z0-9._-]{0,63})/(status|start|stop)$`)
	statusOpenRoute = regexp.MustCompile(`^/__remote_everything/open/([a-z0-9][a-z0-9._-]{0,63})$`)

	controlToken string
	statusClient = &http.Client{Timeout: 7 * time.Second}
)

type statusBody struct {
	OK                bool   `json:"ok"`
	ComputerConnected bool   `json:"computer_connected"`
	Code              string `json:"code"`
}

func statusJSON(value any) json.RawMessage {
	body, err := json.Marshal(value)
	if err != nil {
		body, _ = json.Marshal(errorBody("internal_error"))
	}
	return body
}

func statusOffline() json.RawMessage {
	return statusJSON(statusBody{OK: false, ComputerConnected: false, Code: "computer_offline"})
}

func statusUnavailable() json.RawMessage {
	return statusJSON(statusBody{OK: false, ComputerConnected: true, Code: "control_unavailable"})
}

func readControlToken() (string, error) {
	contents, err := os.ReadFile(controlTokenFile)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(contents)), nil
}

func invokePC(action, appID string) json.RawMessage {
	payload, err := json.Marshal(map[string]string{"action": action, "id": appID})
	if err != nil {
		return statusOffline()
	}
	request, err := http.NewRequest(http.MethodPost, localControlURL, bytes.NewReader(payload))
	if err != nil {
		return statusOffline()
	}
	request.Header.Set("Authorization", "Bearer "+controlToken)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := statusClient.Do(request)
	if err != nil {
		logLine("status-server", "warn", "local control unreachable", "code", "computer_offline")
		return statusOffline()
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return statusOffline()
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024))
	if err != nil {
		return statusOffline()
	}
	var object map[string]json.RawMessage
	if err := json.Unmarshal(body, &object); err != nil {
		return statusUnavailable()
	}
	return json.RawMessage(body)
}

func saveCachedApps(apps []map[string]any) error {
	temporary := strings.TrimSuffix(appsCacheFile, ".json") + ".tmp"
	contents, err := json.Marshal(map[string]any{"apps": apps})
	if err != nil {
		return err
	}
	if err := os.WriteFile(temporary, contents, 0o600); err != nil {
		return err
	}
	if err := replaceFile(temporary, appsCacheFile); err != nil {
		return err
	}
	return os.Chmod(appsCacheFile, 0o600)
}

func cachedApps() []map[string]any {
	contents, err := os.ReadFile(appsCacheFile)
	if err != nil {
		return nil
	}
	var value struct {
		Apps []map[string]any `json:"apps"`
	}
	if err := json.Unmarshal(contents, &value); err != nil {
		return nil
	}
	result := make([]map[string]any, 0, len(value.Apps))
	for _, app := range value.Apps {
		id, _ := app["id"].(string)
		if statusAppID.MatchString(id) {
			result = append(result, app)
		}
	}
	return result
}

type appsShape struct {
	OK   bool             `json:"ok"`
	Apps []map[string]any `json:"apps"`
}

func applicationList() json.RawMessage {
	result := invokePC("list", "")
	var shaped appsShape
	if err := json.Unmarshal(result, &shaped); err == nil && shaped.OK && shaped.Apps != nil {
		if err := saveCachedApps(shaped.Apps); err != nil {
			logLine("status-server", "warn", "apps cache write failed", "path", appsCacheFile)
		}
		return result
	}
	offline := make([]map[string]any, 0, 1)
	for _, app := range cachedApps() {
		app["computer_connected"] = false
		app["running"] = false
		app["code"] = "computer_offline"
		offline = append(offline, app)
	}
	return statusJSON(struct {
		statusBody
		Apps []map[string]any `json:"apps"`
	}{statusBody{OK: true, ComputerConnected: false, Code: "computer_offline"}, offline})
}

func applicationAction(appID, action string) json.RawMessage {
	if !statusAppID.MatchString(appID) || (action != "status" && action != "start" && action != "stop") {
		return statusJSON(statusBody{OK: false, ComputerConnected: true, Code: "command_not_allowed"})
	}
	return invokePC(action, appID)
}

func selectedApp(cookieHeader string) string {
	selected := "kimi"
	for _, part := range strings.Split(cookieHeader, ";") {
		part = strings.TrimSpace(part)
		name, value, found := strings.Cut(part, "=")
		if !found || name != "RemoteEverythingApp" {
			continue
		}
		if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
			value = value[1 : len(value)-1]
		}
		selected = value
	}
	if !statusAppID.MatchString(selected) {
		return "kimi"
	}
	return selected
}

func displayState(code string) (title, detail, color string) {
	switch code {
	case "ready":
		return "远程应用正在运行", "电脑与应用都已连接。请返回手机客户端进入。", "#22c55e"
	case "starting":
		return "远程应用正在启动", "电脑在线，应用正在后台启动，请稍候重试。", "#f59e0b"
	case "stopped":
		return "远程应用当前未启动", "电脑在线，可在手机客户端的应用目录中启动。", "#f59e0b"
	case "control_unavailable":
		return "电脑已连接，控制暂不可用", "安全通道在线，但控制命令暂时没有响应。", "#f59e0b"
	default:
		return "电脑当前未连接", "云端入口运行正常。电脑开机并登录 Windows 后会自动恢复。", "#64748b"
	}
}

const statusPageTemplate = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <meta name="color-scheme" content="dark light">
  <meta http-equiv="refresh" content="8">
  <title>::TITLE::</title>
  <style>
    :root { font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100dvh; display: grid; place-items: center; padding: 24px; background: radial-gradient(circle at top, #172554 0, #0f172a 45%, #020617 100%); color: #e2e8f0; }
    main { width: min(560px, 100%); padding: 34px; border: 1px solid rgba(148,163,184,.18); border-radius: 24px; background: rgba(15,23,42,.78); box-shadow: 0 24px 80px rgba(0,0,0,.35); backdrop-filter: blur(18px); }
    .state { display: flex; align-items: center; gap: 12px; color: ::COLOR::; font-weight: 650; letter-spacing: .02em; }
    .dot { width: 12px; height: 12px; border-radius: 99px; background: currentColor; box-shadow: 0 0 22px currentColor; }
    h1 { margin: 22px 0 12px; font-size: clamp(26px, 7vw, 38px); line-height: 1.14; color: #f8fafc; }
    p { margin: 0; color: #aebbd0; line-height: 1.75; font-size: 16px; }
    .meta { margin-top: 26px; padding-top: 18px; border-top: 1px solid rgba(148,163,184,.14); display: flex; justify-content: space-between; gap: 12px; color: #64748b; font-size: 13px; }
    button { margin-top: 26px; width: 100%; border: 0; border-radius: 14px; padding: 14px 18px; background: #2563eb; color: white; font: inherit; font-weight: 650; cursor: pointer; }
  </style>
</head>
<body>
  <main>
    <div class="state"><span class="dot"></span><span>远程万物云端入口正常</span></div>
    <h1>::TITLE::</h1>
    <p>::DETAIL::</p>
    <button type="button" onclick="location.reload()">立即重试</button>
    <div class="meta"><span>将在 <b id="countdown">8</b> 秒后自动重试</span><span>::NOW::</span></div>
  </main>
  <script>
    let left = 8;
    setInterval(() => { left = Math.max(0, left - 1); document.getElementById('countdown').textContent = left; }, 1000);
  </script>
</body>
</html>`

func renderStatusPage(state json.RawMessage) []byte {
	var probe struct {
		Code string `json:"code"`
	}
	_ = json.Unmarshal(state, &probe)
	title, detail, color := displayState(probe.Code)
	replacer := strings.NewReplacer(
		"::TITLE::", title,
		"::DETAIL::", detail,
		"::COLOR::", color,
		"::NOW::", time.Now().Format("2006-01-02 15:04:05 MST"),
	)
	return []byte(replacer.Replace(statusPageTemplate))
}

func statusCommonHeaders(writer http.ResponseWriter, contentType string, length int) {
	writer.Header().Set("Content-Type", contentType)
	writer.Header().Set("Content-Length", strconv.Itoa(length))
	writer.Header().Set("Cache-Control", "no-store, max-age=0")
	writer.Header().Set("Pragma", "no-cache")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.Header().Set("Content-Security-Policy", statusCSP)
}

func writeStatusJSON(writer http.ResponseWriter, status int, value any) {
	body := statusJSON(value)
	statusCommonHeaders(writer, "application/json; charset=utf-8", len(body))
	writer.WriteHeader(status)
	_, _ = writer.Write(body)
}

func statusAuthorized(request *http.Request) bool {
	expected := "Bearer " + controlToken
	return subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte(expected)) == 1
}

func rawRequestPath(request *http.Request) string {
	raw := request.RequestURI
	if index := strings.IndexByte(raw, '?'); index >= 0 {
		raw = raw[:index]
	}
	return raw
}

func statusHTTPHandler(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		statusGetHandler(writer, request)
	case http.MethodPost:
		statusPostHandler(writer, request)
	default:
		writer.WriteHeader(http.StatusNotImplemented)
	}
}

func statusGetHandler(writer http.ResponseWriter, request *http.Request) {
	path := rawRequestPath(request)
	opened := statusOpenRoute.FindStringSubmatch(path)
	appRoute := statusAppRoute.FindStringSubmatch(path)
	switch {
	case path == "/healthz":
		writeStatusJSON(writer, http.StatusOK, map[string]bool{"ok": true})
	case path == "/__remote_everything/apps":
		if !statusAuthorized(request) {
			writeStatusJSON(writer, http.StatusUnauthorized, errorBody("unauthorized"))
			return
		}
		writeStatusJSON(writer, http.StatusOK, applicationList())
	case opened != nil:
		appID := opened[1]
		var shaped struct {
			Apps []struct {
				ID string `json:"id"`
			} `json:"apps"`
		}
		available := map[string]bool{}
		if err := json.Unmarshal(applicationList(), &shaped); err == nil {
			for _, app := range shaped.Apps {
				available[app.ID] = true
			}
		}
		if !available[appID] {
			writeStatusJSON(writer, http.StatusNotFound, errorBody("app_not_found"))
			return
		}
		writer.Header().Set("Location", "/")
		writer.Header().Set("Set-Cookie", "RemoteEverythingApp="+appID+"; Path=/; Max-Age=86400; Secure; HttpOnly; SameSite=Strict")
		writer.Header().Set("Cache-Control", "no-store")
		writer.Header().Set("Content-Length", "0")
		writer.WriteHeader(http.StatusFound)
	case appRoute != nil && appRoute[2] == "status":
		if !statusAuthorized(request) {
			writeStatusJSON(writer, http.StatusUnauthorized, errorBody("unauthorized"))
			return
		}
		writeStatusJSON(writer, http.StatusOK, applicationAction(appRoute[1], "status"))
	default:
		appID := selectedApp(request.Header.Get("Cookie"))
		body := renderStatusPage(applicationAction(appID, "status"))
		statusCommonHeaders(writer, "text/html; charset=utf-8", len(body))
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write(body)
	}
}

func statusPostHandler(writer http.ResponseWriter, request *http.Request) {
	path := rawRequestPath(request)
	if match := statusAppRoute.FindStringSubmatch(path); match != nil && (match[2] == "start" || match[2] == "stop") {
		if !statusAuthorized(request) {
			writeStatusJSON(writer, http.StatusUnauthorized, errorBody("unauthorized"))
			return
		}
		writeStatusJSON(writer, http.StatusOK, applicationAction(match[1], match[2]))
		return
	}
	writeStatusJSON(writer, http.StatusNotFound, errorBody("not_found"))
}

func serveStatus() {
	token, err := readControlToken()
	if err != nil {
		logLine("status-server", "error", "control token unavailable", "path", controlTokenFile)
		os.Exit(1)
	}
	controlToken = token
	server := &http.Server{
		Addr:              statusListenAddr,
		Handler:           http.HandlerFunc(statusHTTPHandler),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	logLine("status-server", "info", "listening", "path", statusListenAddr)
	if err := server.ListenAndServe(); err != nil {
		logLine("status-server", "error", "server stopped", "code", err.Error())
		os.Exit(1)
	}
}
