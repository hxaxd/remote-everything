package main

import (
	"bytes"
	"encoding/json"
	"net"
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
	request := httptest.NewRequest(http.MethodPost, "/__local_remote_control", bytes.NewBufferString(`{"action":"list"}`))
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
	localControlHandler(denied, httptest.NewRequest(http.MethodPost, "/__local_remote_control", bytes.NewBufferString(`{"action":"list"}`)))
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

func TestInvalidWorkDirRejected(t *testing.T) {
	testRegistry(t)
	value := registry{
		Version: 1,
		Apps: []appDefinition{{
			ID: "kimi", Name: "Kimi Code", Description: "Remote", Icon: "K", Accent: "#2563eb",
			WebURL: "https://example.com/", ProxyURL: "http://127.0.0.1:2", Command: "missing.exe", Probe: "127.0.0.1:1",
			WorkDir: `C:\definitely-not-existing-remote-everything-dir`,
		}},
	}
	contents, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(appsFile, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	result := listApps()
	if result.OK || result.Code != "registry_unavailable" {
		t.Fatalf("expected registry_unavailable: %#v", result)
	}
}

func TestUnknownApplication(t *testing.T) {
	testRegistry(t)
	result := statusApp("missing")
	if result.OK || result.Code != "app_not_found" {
		t.Fatalf("unexpected response: %#v", result)
	}
}

func TestBackoff(t *testing.T) {
	defer func() { baseBackoff, maxBackoff = 2*1_000_000_000, 5*60*1_000_000_000 }()
	if got := backoff(1); got != 2*1_000_000_000 {
		t.Fatalf("backoff(1) = %v", got)
	}
	if got := backoff(2); got != 4*1_000_000_000 {
		t.Fatalf("backoff(2) = %v", got)
	}
	if got := backoff(3); got != 8*1_000_000_000 {
		t.Fatalf("backoff(3) = %v", got)
	}
	if got := backoff(30); got != 5*60*1_000_000_000 {
		t.Fatalf("backoff(30) = %v, want cap", got)
	}
}

func TestLogRotation(t *testing.T) {
	testRegistry(t)
	path := filepath.Join(logsRoot, "kimi.log")
	if err := os.MkdirAll(logsRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, maxLogBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	file, err := openLogFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString("fresh\n"); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(path + ".old"); err != nil || info.Size() != maxLogBytes+1 {
		t.Fatalf("old generation missing or wrong size: %v", err)
	}
	if info, err := os.Stat(path); err != nil || info.Size() != int64(len("fresh\n")) {
		t.Fatalf("rotated file wrong size: %v", err)
	}
}

func TestControlLog(t *testing.T) {
	testRegistry(t)
	if err := os.MkdirAll(logsRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	controlLog("test event id=%s", "kimi")
	contents, err := os.ReadFile(filepath.Join(logsRoot, "control.log"))
	if err != nil || !bytes.Contains(contents, []byte("test event id=kimi")) {
		t.Fatalf("control.log missing entry: %v %q", err, contents)
	}
}

func TestStopAppReportsStopping(t *testing.T) {
	testRegistry(t)
	stopWaitAttempts, stopWaitInterval = 2, 10*1_000_000
	defer func() { stopWaitAttempts, stopWaitInterval = 20, 200*1_000_000 }()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	value := registry{
		Version: 1,
		Apps: []appDefinition{{
			ID: "kimi", Name: "Kimi Code", Description: "Remote", Icon: "K", Accent: "#2563eb",
			WebURL: "https://example.com/", ProxyURL: "http://127.0.0.1:2", Command: "missing.exe", Probe: listener.Addr().String(),
		}},
	}
	contents, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(appsFile, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	result := stopApp("kimi")
	if !result.OK || result.Code != "stopping" || result.App == nil || result.App.Code != "stopping" {
		t.Fatalf("expected stopping state: %#v", result)
	}
}
