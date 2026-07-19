package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type statusFixture struct {
	upstream *httptest.Server
	requests []string
	handler  func(action, id string) (int, string)
}

func setupStatus(t *testing.T) *statusFixture {
	t.Helper()
	fixture := &statusFixture{}
	directory := t.TempDir()
	appsCacheFile = filepath.Join(directory, "apps-cache.json")
	controlToken = "test-control-token"
	logOut = io.Discard
	fixture.handler = func(action, id string) (int, string) {
		return 200, `{"ok":true,"computer_connected":true,"code":"ready"}`
	}
	fixture.upstream = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer test-control-token" {
			writer.WriteHeader(401)
			return
		}
		var payload struct {
			Action string `json:"action"`
			ID     string `json:"id"`
		}
		body, _ := io.ReadAll(request.Body)
		if err := json.Unmarshal(body, &payload); err != nil {
			writer.WriteHeader(400)
			return
		}
		fixture.requests = append(fixture.requests, payload.Action+"/"+payload.ID)
		status, response := fixture.handler(payload.Action, payload.ID)
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(status)
		_, _ = writer.Write([]byte(response))
	}))
	localControlURL = fixture.upstream.URL
	t.Cleanup(func() {
		fixture.upstream.Close()
		appsCacheFile = "/var/lib/remote-everything-control/apps-cache.json"
		localControlURL = "http://127.0.0.1:58628/__local_remote_control"
		controlToken = ""
		logOut = os.Stdout
	})
	return fixture
}

func statusRequest(t *testing.T, method, target, token, cookie string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(method, target, nil)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if cookie != "" {
		request.Header.Set("Cookie", cookie)
	}
	recorder := httptest.NewRecorder()
	statusHTTPHandler(recorder, request)
	return recorder
}

func TestStatusHealthz(t *testing.T) {
	setupStatus(t)
	recorder := statusRequest(t, "GET", "/healthz", "", "")
	if recorder.Code != 200 || recorder.Body.String() != `{"ok":true}` {
		t.Fatalf("healthz: %d %s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Content-Security-Policy") != statusCSP ||
		recorder.Header().Get("Cache-Control") != "no-store, max-age=0" ||
		recorder.Header().Get("Pragma") != "no-cache" ||
		recorder.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("missing headers: %v", recorder.Header())
	}
}

func TestStatusUnauthorized(t *testing.T) {
	setupStatus(t)
	for _, target := range []string{"/__remote_everything/apps", "/__remote_everything/apps/kimi/status"} {
		recorder := statusRequest(t, "GET", target, "", "")
		if recorder.Code != 401 || recorder.Body.String() != `{"ok":false,"code":"unauthorized"}` {
			t.Fatalf("%s: expected 401: %d %s", target, recorder.Code, recorder.Body.String())
		}
	}
	recorder := statusRequest(t, "POST", "/__remote_everything/apps/kimi/start", "wrong", "")
	if recorder.Code != 401 {
		t.Fatalf("wrong token: %d", recorder.Code)
	}
	recorder = statusRequest(t, "GET", "/__remote_everything/apps", "test-control-token", "")
	if recorder.Code != 200 {
		t.Fatalf("authorized: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestStatusAppIDValidation(t *testing.T) {
	setupStatus(t)
	if got := string(applicationAction("Bad-ID", "start")); got != `{"ok":false,"computer_connected":true,"code":"command_not_allowed"}` {
		t.Fatalf("bad id: %s", got)
	}
	if got := string(applicationAction("kimi", "delete")); got != `{"ok":false,"computer_connected":true,"code":"command_not_allowed"}` {
		t.Fatalf("bad action: %s", got)
	}
	// Routes reject invalid ids before auth.
	recorder := statusRequest(t, "POST", "/__remote_everything/apps/Bad-ID/start", "test-control-token", "")
	if recorder.Code != 404 || recorder.Body.String() != `{"ok":false,"code":"not_found"}` {
		t.Fatalf("bad route id: %d %s", recorder.Code, recorder.Body.String())
	}
}

func TestStatusOfflineCacheFallback(t *testing.T) {
	fixture := setupStatus(t)
	fixture.handler = func(action, id string) (int, string) {
		return 500, `{"ok":false}`
	}
	if got := string(applicationList()); got != `{"ok":true,"computer_connected":false,"code":"computer_offline","apps":[]}` {
		t.Fatalf("offline without cache: %s", got)
	}

	cache := `{"apps":[{"id":"kimi","name":"Kimi","computer_connected":true,"running":true,"code":"ready"},{"id":"bad id!!","name":"skip"},{"id":"notes","name":"Notes","enabled":false}]}`
	if err := os.WriteFile(appsCacheFile, []byte(cache), 0o600); err != nil {
		t.Fatal(err)
	}
	var fallback struct {
		Apps []map[string]any `json:"apps"`
	}
	if err := json.Unmarshal(applicationList(), &fallback); err != nil || len(fallback.Apps) != 2 {
		t.Fatalf("offline cache fallback: %v", err)
	}
	if fallback.Apps[0]["id"] != "kimi" || fallback.Apps[1]["id"] != "notes" {
		t.Fatalf("cache id filtering wrong: %v", fallback.Apps)
	}
	for _, app := range fallback.Apps {
		if app["computer_connected"] != false || app["running"] != false || app["code"] != "computer_offline" {
			t.Fatalf("offline fields not applied: %v", app)
		}
	}

	// A healthy upstream refreshes the cache and passes through unchanged.
	fixture.handler = func(action, id string) (int, string) {
		return 200, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"kimi","name":"Kimi 中文","running":true,"code":"ready"}]}`
	}
	passthrough := string(applicationList())
	if !strings.Contains(passthrough, `"Kimi 中文"`) {
		t.Fatalf("passthrough lost data: %s", passthrough)
	}
	contents, err := os.ReadFile(appsCacheFile)
	if err != nil || !strings.Contains(string(contents), `"Kimi 中文"`) {
		t.Fatalf("cache not refreshed: %v %s", err, contents)
	}

	// Invalid JSON from upstream reports control_unavailable.
	fixture.handler = func(action, id string) (int, string) {
		return 200, `not json`
	}
	var invalidUpstream struct {
		Apps []map[string]any `json:"apps"`
	}
	if err := json.Unmarshal(applicationList(), &invalidUpstream); err != nil || len(invalidUpstream.Apps) != 1 ||
		invalidUpstream.Apps[0]["code"] != "computer_offline" || invalidUpstream.Apps[0]["computer_connected"] != false ||
		invalidUpstream.Apps[0]["running"] != false {
		t.Fatalf("invalid json upstream should fall back to cache: %v", invalidUpstream.Apps)
	}
	if got := string(invokePC("status", "kimi")); got != `{"ok":false,"computer_connected":true,"code":"control_unavailable"}` {
		t.Fatalf("invoke_pc invalid json: %s", got)
	}
}

func TestStatusOpenRoute(t *testing.T) {
	fixture := setupStatus(t)
	fixture.handler = func(action, id string) (int, string) {
		return 200, `{"ok":true,"apps":[{"id":"kimi"}]}`
	}
	// No Authorization header on purpose: the open route is not token-gated.
	recorder := statusRequest(t, "GET", "/__remote_everything/open/kimi", "", "")
	if recorder.Code != 302 {
		t.Fatalf("open: %d %s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Location") != "/" {
		t.Fatalf("open location: %v", recorder.Header())
	}
	cookie := recorder.Header().Get("Set-Cookie")
	if cookie != "RemoteEverythingApp=kimi; Path=/; Max-Age=86400; Secure; HttpOnly; SameSite=Strict" {
		t.Fatalf("open cookie: %q", cookie)
	}
	if recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("open cache control: %v", recorder.Header())
	}
	unknown := statusRequest(t, "GET", "/__remote_everything/open/unknown", "", "")
	if unknown.Code != 404 {
		t.Fatalf("open unknown: %d", unknown.Code)
	}
	if body := unknown.Body.String(); body != `{"ok":false,"code":"app_not_found"}` {
		t.Fatalf("open unknown body: %s", body)
	}
}

func TestStatusPage(t *testing.T) {
	fixture := setupStatus(t)
	fixture.handler = func(action, id string) (int, string) {
		return 200, `{"ok":true,"computer_connected":true,"running":true,"code":"ready"}`
	}
	recorder := statusRequest(t, "GET", "/", "", "RemoteEverythingApp=kimi")
	if recorder.Code != 200 || !strings.HasPrefix(recorder.Header().Get("Content-Type"), "text/html") {
		t.Fatalf("page: %d %v", recorder.Code, recorder.Header())
	}
	body := recorder.Body.String()
	if !strings.Contains(body, "远程应用正在运行") || !strings.Contains(body, "#22c55e") ||
		!strings.Contains(body, "远程万物云端入口正常") || !strings.Contains(body, `lang="zh-CN"`) {
		t.Fatalf("page body wrong: %s", body)
	}
	if recorder.Header().Get("Content-Security-Policy") != statusCSP {
		t.Fatal("page missing CSP")
	}
	if len(fixture.requests) != 1 || fixture.requests[0] != "status/kimi" {
		t.Fatalf("page queried wrong app: %v", fixture.requests)
	}

	// Unknown cookie value falls back to kimi.
	statusRequest(t, "GET", "/", "", "RemoteEverythingApp=not!!valid")
	if fixture.requests[1] != "status/kimi" {
		t.Fatalf("invalid cookie should fall back: %v", fixture.requests)
	}

	fixture.handler = func(action, id string) (int, string) {
		return 500, `{"ok":false}`
	}
	recorder = statusRequest(t, "GET", "/", "", "")
	if !strings.Contains(recorder.Body.String(), "电脑当前未连接") {
		t.Fatalf("offline page: %s", recorder.Body.String())
	}
}

func TestStatusPostRoutes(t *testing.T) {
	fixture := setupStatus(t)
	recorder := statusRequest(t, "POST", "/__remote_everything/apps/kimi/start", "test-control-token", "")
	if recorder.Code != 200 || fixture.requests[0] != "start/kimi" {
		t.Fatalf("start: %d %v", recorder.Code, fixture.requests)
	}
	recorder = statusRequest(t, "POST", "/__remote_everything/apps/kimi/stop", "test-control-token", "")
	if recorder.Code != 200 || fixture.requests[1] != "stop/kimi" {
		t.Fatalf("stop: %d %v", recorder.Code, fixture.requests)
	}
	if recorder := statusRequest(t, "POST", "/__remote_everything/apps", "test-control-token", ""); recorder.Code != 404 {
		t.Fatalf("post apps: %d", recorder.Code)
	}
	// GET on a start/stop route falls through to the status page, like Python.
	recorder = statusRequest(t, "GET", "/__remote_everything/apps/kimi/start", "", "")
	if recorder.Code != 200 || !strings.Contains(recorder.Body.String(), "远程应用正在运行") {
		t.Fatalf("get start route should render page: %d", recorder.Code)
	}
}
