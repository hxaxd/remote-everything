package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func testRegistry(t *testing.T) {
	t.Helper()
	stateRoot = t.TempDir()
	appsFile = filepath.Join(stateRoot, "apps.json")
	enabledRoot = filepath.Join(stateRoot, "enabled")
	logsRoot = filepath.Join(stateRoot, "logs")
	controlTokenFile = filepath.Join(stateRoot, "control-token")
	value := registry{
		Version: 1,
		Apps: []appDefinition{{
			ID: "kimi", Name: "Kimi Code", Description: "Remote", Icon: "K", Accent: "#2563eb",
			WebURL: "https://example.com/", ProxyURL: "http://127.0.0.1:2", Command: "missing.exe", Probe: "127.0.0.1:1",
		}},
	}
	contents, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(appsFile, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(controlTokenFile, []byte("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestLocalControl(t *testing.T) {
	testRegistry(t)
	request := httptest.NewRequest(http.MethodPost, "/__local_agent_control", bytes.NewBufferString(`{"action":"list"}`))
	request.Header.Set("Authorization", "Bearer 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	recorder := httptest.NewRecorder()
	localControlHandler(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d", recorder.Code)
	}
	var result response
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil || !result.OK || len(result.Apps) != 1 {
		t.Fatalf("unexpected response: %s", recorder.Body.String())
	}

	denied := httptest.NewRecorder()
	localControlHandler(denied, httptest.NewRequest(http.MethodPost, "/__local_agent_control", bytes.NewBufferString(`{"action":"list"}`)))
	if denied.Code != http.StatusUnauthorized {
		t.Fatalf("unexpected denied status: %d", denied.Code)
	}
}

func TestListAndState(t *testing.T) {
	testRegistry(t)
	listed := listApps()
	if !listed.OK || len(listed.Apps) != 1 || listed.Apps[0].Code != "stopped" {
		t.Fatalf("unexpected list response: %#v", listed)
	}
	started := startApp("kimi")
	if !started.OK || started.Code != "starting" || !isEnabled("kimi") {
		t.Fatalf("unexpected start response: %#v", started)
	}
	stopped := stopApp("kimi")
	if !stopped.OK || stopped.Code != "stopped" || isEnabled("kimi") {
		t.Fatalf("unexpected stop response: %#v", stopped)
	}
}

func TestUnknownApplication(t *testing.T) {
	testRegistry(t)
	result := statusApp("missing")
	if result.OK || result.Code != "app_not_found" {
		t.Fatalf("unexpected response: %#v", result)
	}
}
