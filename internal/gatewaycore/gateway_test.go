package gatewaycore

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" // gitleaks:allow -- deterministic test fixture

func newTestGateway(t *testing.T, application http.HandlerFunc) (*Gateway, *httptest.Server) {
	t.Helper()
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/__local_remote_control" {
			if request.Header.Get("Authorization") != "Bearer "+testToken {
				t.Fatalf("control token not injected")
			}
			var command map[string]string
			if err := json.NewDecoder(request.Body).Decode(&command); err != nil {
				t.Fatal(err)
			}
			if command["action"] == "list" {
				apps := []ApplicationState{{ID: "demo", Name: "Demo", Description: "", Icon: "D", Accent: "#2563eb", ComputerConnected: true, Enabled: true, Running: true, Code: "ready"}}
				WriteJSON(writer, http.StatusOK, ControlResponse{OK: true, ComputerConnected: true, Code: "ready", Apps: apps})
				return
			}
			WriteJSON(writer, http.StatusOK, map[string]any{"ok": true, "action": command["action"], "computer_connected": true, "enabled": true, "running": true, "code": "ready", "app": map[string]any{"id": "demo", "name": "Demo", "description": "", "icon": "D", "accent": "#2563eb", "computer_connected": true, "enabled": true, "running": true, "code": "ready"}})
			return
		}
		application(writer, request)
	}))
	t.Cleanup(node.Close)
	gateway, err := New(node.URL, testToken)
	if err != nil {
		t.Fatal(err)
	}
	return gateway, node
}

func TestConnectedListRejectsUnknownAndInconsistentNodeCatalogs(t *testing.T) {
	for _, body := range []string{
		`{"ok":true,"computer_connected":true,"code":"ready","apps":[],"legacy":true}`,
		`{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"demo","name":"Demo","description":"","icon":"D","accent":"#2563eb","computer_connected":true,"enabled":false,"running":false,"code":"ready"}]}`,
	} {
		node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) { _, _ = writer.Write([]byte(body)) }))
		gateway, err := New(node.URL, testToken)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := gateway.ConnectedList(); ok {
			t.Fatalf("accepted malformed node catalog: %s", body)
		}
		node.Close()
	}
}

func TestOfflineActionUsesTheSameProtocolShape(t *testing.T) {
	gateway, node := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {})
	node.Close()
	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/__remote_everything/apps/demo/start", nil))
	if response.Body.String() != `{"ok":false,"action":"start","computer_connected":false,"enabled":false,"running":false,"code":"computer_offline"}` {
		t.Fatalf("unexpected offline action: %s", response.Body.String())
	}
}

// The node is a concrete address a gateway dials, which may be another machine
// on the same network: a name or an unspecified address gives the gateway
// nothing to connect to.
func TestNewAcceptsAnyConcreteNodeAddressAndRejectsTheRest(t *testing.T) {
	if _, err := New("http://192.168.1.10:58627", testToken); err != nil {
		t.Fatalf("a node on the network was rejected: %v", err)
	}
	for _, nodeURL := range []string{"http://example.com:1234", "http://0.0.0.0:1234", "https://192.168.1.10:58627", "http://192.168.1.10"} {
		if _, err := New(nodeURL, testToken); err == nil {
			t.Fatalf("node URL %q was accepted", nodeURL)
		}
	}
	if _, err := New("http://127.0.0.1:1234", "weak"); err == nil {
		t.Fatal("invalid control token accepted")
	}
}

func TestCatalogActionAndOpenContract(t *testing.T) {
	gateway, _ := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {
		WriteJSON(writer, http.StatusOK, map[string]bool{"proxied": true})
	})

	for _, request := range []*http.Request{
		httptest.NewRequest(http.MethodGet, "/__remote_everything/apps", nil),
		httptest.NewRequest(http.MethodPost, "/__remote_everything/apps/demo/start", nil),
	} {
		response := httptest.NewRecorder()
		gateway.ServeHTTP(response, request)
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"computer_connected":true`) {
			t.Fatalf("unexpected API response: %d %s", response.Code, response.Body.String())
		}
		if response.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Fatalf("writeRaw missing nosniff on %s: %#v", request.URL.Path, response.Header())
		}
	}

	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/__remote_everything/open/demo", nil))
	if response.Code != http.StatusFound || response.Header().Get("Location") != "/" {
		t.Fatalf("unexpected open response: %d", response.Code)
	}
	cookies := response.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != "RemoteEverythingApp" || cookies[0].Value != "demo" || !cookies[0].Secure || !cookies[0].HttpOnly {
		t.Fatalf("unexpected application cookie: %#v", cookies)
	}
}

func TestProxyPreservesRequestAndStripsInternalHeaders(t *testing.T) {
	var capturedHost string
	gateway, _ := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {
		capturedHost = request.Host
		if request.URL.Path != "/room/ws" || request.URL.RawQuery != "a=1" {
			t.Errorf("request target changed: path=%q query=%q", request.URL.Path, request.URL.RawQuery)
		}
		if request.Header.Get("Cookie") != "session=value" || request.Header.Get("Upgrade") != "websocket" {
			t.Errorf("cookie or upgrade header lost")
		}
		if request.Header.Get("Authorization") != "secret" {
			t.Errorf("application authorization header lost")
		}
		for _, name := range []string{"X-Remote-Everything-Client-Fingerprint", "X-Remote-Everything-Control-Token"} {
			if request.Header.Get(name) != "" {
				t.Errorf("internal header %s leaked", name)
			}
		}
		writer.Header().Add("Set-Cookie", "RemoteEverythingApp=attacker; Path=/; HttpOnly")
		writer.Header().Add("Set-Cookie", "session=value; Path=/; HttpOnly")
		WriteJSON(writer, http.StatusOK, map[string]bool{"ok": true})
	})
	request := httptest.NewRequest(http.MethodGet, "https://gateway.example/room/ws?a=1", nil)
	request.Host = "gateway.example"
	request.Header.Set("Cookie", "session=value")
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Authorization", "secret")
	request.Header.Set("X-Remote-Everything-Client-Fingerprint", "secret")
	request.Header.Set("X-Remote-Everything-Control-Token", "secret")
	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("unexpected proxy response: %d %s", response.Code, response.Body.String())
	}
	if capturedHost != "gateway.example" {
		t.Errorf("upstream Host should preserve the public entrance host, got %q", capturedHost)
	}
	cookies := response.Header().Values("Set-Cookie")
	if len(cookies) != 1 || !strings.HasPrefix(cookies[0], "session=value") {
		t.Fatalf("application could overwrite routing cookie or its own cookie was lost: %#v", cookies)
	}
}

func TestLocalControlRouteCannotReachNode(t *testing.T) {
	gateway, _ := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {
		t.Fatalf("private route reached node: %s", request.URL.Path)
	})
	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/__local_remote_control", nil))
	if response.Code != http.StatusForbidden {
		t.Fatalf("local control route returned %d", response.Code)
	}
}

func TestEncodedControlRouteCannotReachNode(t *testing.T) {
	gateway, _ := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {
		t.Fatalf("encoded control path reached node: %s", request.URL.Path)
	})
	response := httptest.NewRecorder()
	gateway.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/%5f%5flocal_remote_control", nil))
	if response.Code != http.StatusForbidden {
		t.Fatalf("encoded local control route returned %d", response.Code)
	}
}
