package nodecore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type testPlatform struct{ commandErr error }

func (testPlatform) PrepareLifetime() (func(), error) { return func() {}, nil }
func (platform testPlatform) RunCommand(context.Context, string, ...string) error {
	return platform.commandErr
}
func (testPlatform) Launch(AppDefinition, io.Writer) (ManagedProcess, error) {
	panic("not used")
}

func initializeTestNode(t *testing.T) (*Node, InitResult) {
	t.Helper()
	result, err := Initialize(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	node, err := Open(result.State, testPlatform{})
	if err != nil {
		t.Fatal(err)
	}
	return node, result
}

func TestInitializeAllocatesStableAvailableLoopbackAddress(t *testing.T) {
	listener, _ := net.Listen("tcp4", "127.0.0.1:58627")
	if listener != nil {
		defer listener.Close()
	}
	root := t.TempDir()
	first, err := Initialize(root, "")
	if err != nil {
		t.Fatal(err)
	}
	if !validLoopbackAddress(first.ListenAddress) || (listener != nil && first.ListenAddress == "127.0.0.1:58627") || len(first.InstallationID) != 64 {
		t.Fatalf("unexpected init result: %+v", first)
	}
	second, err := Initialize(root, "")
	if err != nil || second.ListenAddress != first.ListenAddress || second.InstallationID != first.InstallationID {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
}

func TestRepairPortsPreservesInstallationIdentity(t *testing.T) {
	root := t.TempDir()
	first, err := Initialize(root, "")
	if err != nil {
		t.Fatal(err)
	}
	repaired, err := RepairPorts(root)
	if err != nil {
		t.Fatal(err)
	}
	if repaired.InstallationID != first.InstallationID || !validLoopbackAddress(repaired.ListenAddress) {
		t.Fatalf("unexpected repaired state: %+v", repaired)
	}
}

func TestRegistryRejectsUnknownFieldsAndNodeSelfProxy(t *testing.T) {
	node, result := initializeTestNode(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	definition := map[string]any{
		"id": "self", "name": "Self", "description": "", "icon": "S", "accent": "#000000",
		"proxy_url": "http://" + result.ListenAddress, "command": executable,
		"arguments": []string{}, "stop_command": "", "stop_arguments": []string{}, "workdir": "",
	}
	contents, _ := json.Marshal(definition)
	path := filepath.Join(t.TempDir(), "definition.json")
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := node.readAppDefinition(path); err == nil {
		t.Fatal("node accepted an application proxying to itself")
	}
	definition["proxy_url"] = "http://127.0.0.1:60000"
	definition["web_url"] = "https://obsolete.invalid"
	contents, _ = json.Marshal(definition)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := node.readAppDefinition(path); err == nil {
		t.Fatal("node accepted an obsolete or unknown field")
	}
}

func TestRegistryRejectsInvalidMetadataAndURLFragment(t *testing.T) {
	node, _ := initializeTestNode(t)
	executable, _ := os.Executable()
	base := AppDefinition{
		ID: "fixture", Name: "Fixture", Description: "", Icon: "F", Accent: "#2563eb",
		ProxyURL: "http://127.0.0.1:60000", Command: executable, Arguments: []string{}, StopArgs: []string{},
	}
	tests := []AppDefinition{base, base, base, base}
	tests[0].Name = "<script>" + strings.Repeat("x", 80)
	tests[1].Description = "line\nbreak"
	tests[2].Accent = "red"
	tests[3].ProxyURL += "#fragment"
	for _, app := range tests {
		if err := node.validateRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{app}}); err == nil {
			t.Fatalf("invalid application metadata accepted: %+v", app)
		}
	}
}

func TestGatewayMessageEscapesApplicationMetadata(t *testing.T) {
	recorder := httptest.NewRecorder()
	gatewayMessage(recorder, http.StatusBadGateway, `<script>alert(1)</script>`, `<img src=x onerror=alert(1)>`)
	if strings.Contains(recorder.Body.String(), "<script>") || strings.Contains(recorder.Body.String(), "<img") {
		t.Fatalf("gateway error page contains raw metadata: %s", recorder.Body.String())
	}
}

func TestProxyStripsEveryInternalHeader(t *testing.T) {
	var received http.Header
	application := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		received = request.Header.Clone()
		_, _ = io.WriteString(writer, "ok")
	}))
	defer application.Close()
	node, _ := initializeTestNode(t)
	executable, _ := os.Executable()
	target, _ := url.Parse(application.URL)
	app := AppDefinition{
		ID: "fixture", Name: "Fixture", Icon: "F", Accent: "#2563eb", ProxyURL: "http://127.0.0.1:" + target.Port(), Command: executable,
		Arguments: []string{}, StopArgs: []string{},
	}
	if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{app}}); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Cookie", "RemoteEverythingApp=fixture")
	request.Header.Set("Authorization", "secret")
	request.Header.Set("X-Remote-Everything-Client-Fingerprint", strings.Repeat("ab", 32))
	request.Header.Set("X-Remote-Everything-Control-Token", "secret")
	recorder := httptest.NewRecorder()
	node.gatewayHandler(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Body.String() != "ok" {
		t.Fatalf("proxy response = %d %q", recorder.Code, recorder.Body.String())
	}
	for _, name := range []string{"Authorization", "X-Remote-Everything-Client-Fingerprint", "X-Remote-Everything-Control-Token"} {
		if received.Get(name) != "" {
			t.Fatalf("internal header leaked: %s", name)
		}
	}
}

func TestControlRejectsTrailingJSON(t *testing.T) {
	node, _ := initializeTestNode(t)
	token, _ := os.ReadFile(node.controlTokenFile)
	request := httptest.NewRequest(http.MethodPost, "/__local_remote_control", bytes.NewBufferString(`{"action":"list"}{}`))
	request.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	recorder := httptest.NewRecorder()
	node.localControlHandler(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("trailing JSON status = %d", recorder.Code)
	}
}

func TestAppStateCodeCoversDesiredAndObservedState(t *testing.T) {
	tests := []struct {
		enabled bool
		running bool
		want    string
	}{
		{enabled: true, running: true, want: "ready"},
		{enabled: true, running: false, want: "starting"},
		{enabled: false, running: true, want: "stopping"},
		{enabled: false, running: false, want: "stopped"},
	}
	for _, test := range tests {
		if got := applicationStateCode(test.enabled, test.running); got != test.want {
			t.Fatalf("applicationStateCode(%t, %t) = %q, want %q", test.enabled, test.running, got, test.want)
		}
	}
}

func TestActionResponseIncludesFalseStateFields(t *testing.T) {
	contents, err := json.Marshal(actionResponse{OK: true, Action: "stop", Code: "stopped"})
	if err != nil {
		t.Fatal(err)
	}
	text := string(contents)
	if !strings.Contains(text, `"enabled":false`) || !strings.Contains(text, `"running":false`) {
		t.Fatalf("response omitted explicit false state: %s", text)
	}
}

func TestStopCommandFailureIsObservableWithoutLosingState(t *testing.T) {
	node, _ := initializeTestNode(t)
	node.platform = testPlatform{commandErr: errors.New("stop failed")}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	app := AppDefinition{
		ID: "fixture", Name: "Fixture", Icon: "F", Accent: "#2563eb", ProxyURL: "http://127.0.0.1:60000", Command: executable,
		Arguments: []string{}, StopCommand: executable, StopArgs: []string{},
	}
	if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{app}}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(node.enabledPath(app.ID), []byte("enabled\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	result := node.stopApp(app.ID)
	if result.OK || result.ErrorCode != "stop_command_failed" || result.Enabled || result.Code != "stopped" {
		t.Fatalf("stop failure was hidden or state was lost: %+v", result)
	}
}
