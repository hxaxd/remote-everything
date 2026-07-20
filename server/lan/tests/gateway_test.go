package tests

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

var testToken = strings.Repeat("01", 32)

func setup(t *testing.T) (*httptest.Server, *[]string) {
	t.Helper()
	requests := []string{}
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/__local_remote_control" {
			if request.Header.Get("Authorization") != "Bearer "+testToken {
				writer.WriteHeader(http.StatusUnauthorized)
				return
			}
			var input struct {
				Action string `json:"action"`
				ID     string `json:"id"`
			}
			_ = json.NewDecoder(request.Body).Decode(&input)
			requests = append(requests, input.Action+"/"+input.ID)
			writer.Header().Set("Content-Type", "application/json")
			if input.Action == "list" {
				_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
				return
			}
			_, _ = io.WriteString(writer, `{"ok":true,"action":"`+input.Action+`","computer_connected":true,"enabled":true,"running":true,"code":"ready","app":{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}}`)
			return
		}
		_, _ = io.WriteString(writer, request.URL.RequestURI()+"|"+request.Header.Get("Authorization"))
	}))
	t.Cleanup(node.Close)
	return node, &requests
}

func request(t *testing.T, handler http.Handler, method, target, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func TestControlAPI(t *testing.T) {
	node, calls := setup(t)
	handler, err := gatewaycore.New(node.URL, testToken)
	if err != nil {
		t.Fatal(err)
	}
	list := request(t, handler, "GET", "/__remote_everything/apps", "")
	if list.Code != http.StatusOK || !strings.Contains(list.Body.String(), `"id":"editor"`) {
		t.Fatalf("list: %d %s", list.Code, list.Body.String())
	}
	status := request(t, handler, "GET", "/__remote_everything/apps/editor/status", "")
	start := request(t, handler, "POST", "/__remote_everything/apps/editor/start", "")
	if status.Code != http.StatusOK || start.Code != http.StatusOK {
		t.Fatalf("actions: %d %d", status.Code, start.Code)
	}
	if strings.Join(*calls, ",") != "list/,status/editor,start/editor" {
		t.Fatalf("control calls: %v", *calls)
	}
}

func TestOpenAndProxy(t *testing.T) {
	node, _ := setup(t)
	handler, _ := gatewaycore.New(node.URL, testToken)
	opened := request(t, handler, "GET", "/__remote_everything/open/editor", "")
	if opened.Code != http.StatusFound || opened.Header().Get("Location") != "/" || !strings.Contains(opened.Header().Get("Set-Cookie"), "RemoteEverythingApp=editor") {
		t.Fatalf("open: %d %v", opened.Code, opened.Header())
	}
	proxied := request(t, handler, "GET", "/path?q=1", testToken)
	if proxied.Code != http.StatusOK || proxied.Body.String() != "/path?q=1|Bearer "+testToken {
		t.Fatalf("proxy lost application authorization or changed path: %d %q", proxied.Code, proxied.Body.String())
	}
	forbidden := request(t, handler, "POST", "/__local_remote_control", testToken)
	if forbidden.Code != http.StatusForbidden {
		t.Fatalf("local control exposed: %d", forbidden.Code)
	}
}

func TestOfflineList(t *testing.T) {
	node, _ := setup(t)
	handler, _ := gatewaycore.New(node.URL, testToken)
	node.Close()
	result := request(t, handler, "GET", "/__remote_everything/apps", "")
	if result.Body.String() != `{"ok":true,"computer_connected":false,"code":"computer_offline","apps":[]}` {
		t.Fatalf("offline: %s", result.Body.String())
	}
}

func TestGatewayRejectsNonLocalNodeAndInvalidToken(t *testing.T) {
	if _, err := gatewaycore.New("http://192.0.2.1:58627", testToken); err == nil {
		t.Fatal("accepted a non-loopback node")
	}
	if _, err := gatewaycore.New("http://127.0.0.1:58627", "not-a-control-token"); err == nil {
		t.Fatal("accepted an invalid control token")
	}
}
