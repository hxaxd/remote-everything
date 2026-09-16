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

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
)

type testPlatform struct{ commandErr error }

func (testPlatform) PrepareLifetime() (func(), error) { return func() {}, nil }
func (platform testPlatform) RunCommand(context.Context, string, ...string) error {
	return platform.commandErr
}
func (testPlatform) Launch(AppDefinition, io.Writer) (ManagedProcess, error) {
	panic("not used")
}

func initializeTestNode(t *testing.T) (*Node, BindingResult) {
	t.Helper()
	result, err := Initialize(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	node, err := Open(result.State, testPlatform{})
	if err != nil {
		t.Fatal(err)
	}
	return node, result
}

func testFreePort(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	listener.Close()
	return port
}

func TestInitializeAllocatesStableAvailableLoopbackAddress(t *testing.T) {
	listener, _ := net.Listen("tcp4", "127.0.0.1:58627")
	if listener != nil {
		defer listener.Close()
	}
	root := t.TempDir()
	first, err := Initialize(root)
	if err != nil {
		t.Fatal(err)
	}
	if !validLoopbackAddress(first.ListenAddress) || (listener != nil && first.ListenAddress == "127.0.0.1:58627") || len(first.NodeID) != 64 {
		t.Fatalf("unexpected init result: %+v", first)
	}
	second, err := Initialize(root)
	if err != nil || second.ListenAddress != first.ListenAddress || second.NodeID != first.NodeID {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
}

func TestRepairPortsPreservesNodeIdentity(t *testing.T) {
	root := t.TempDir()
	first, err := Initialize(root)
	if err != nil {
		t.Fatal(err)
	}
	repaired, err := RepairPorts(root)
	if err != nil {
		t.Fatal(err)
	}
	if repaired.NodeID != first.NodeID || !validLoopbackAddress(repaired.ListenAddress) {
		t.Fatalf("unexpected repaired state: %+v", repaired)
	}
}

func TestRepairPortsSkipsRegisteredApplicationAddress(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:58627")
	if err != nil {
		t.Skip("preferred port unavailable on this machine")
	}
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	node, err := Open(root, testPlatform{})
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	app := AppDefinition{
		ID: "fixture", Name: "Fixture", Icon: "F", Accent: "#2563eb", ProxyURL: "http://127.0.0.1:58627", Command: executable,
		Arguments: []string{}, StopArgs: []string{},
	}
	if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{app}}); err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	repaired, err := RepairPorts(root)
	if err != nil {
		t.Fatal(err)
	}
	if repaired.ListenAddress == "127.0.0.1:58627" {
		t.Fatalf("repair stole registered application address: %+v", repaired)
	}
	if _, err := Open(root, testPlatform{}); err != nil {
		t.Fatalf("node cannot start after repair: %v", err)
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

func TestRegistryAcceptsOnlyHashLaunchFragments(t *testing.T) {
	node, _ := initializeTestNode(t)
	executable, _ := os.Executable()
	valid := AppDefinition{
		ID: "fixture", Name: "Fixture", Icon: "F", Accent: "#2563eb", LaunchFragment: "#token=value",
		ProxyURL: "http://127.0.0.1:60000", Command: executable, Arguments: []string{}, StopArgs: []string{},
	}
	if err := node.validateRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{valid}}); err != nil {
		t.Fatalf("valid launch fragment rejected: %v", err)
	}
	for _, fragment := range []string{"token=value", "#line\nbreak"} {
		invalid := valid
		invalid.LaunchFragment = fragment
		if err := node.validateRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{invalid}}); err == nil {
			t.Fatalf("invalid launch fragment accepted: %q", fragment)
		}
	}
}

func TestRegistryRejectsProxyURLWithPathOrQuery(t *testing.T) {
	node, _ := initializeTestNode(t)
	executable, _ := os.Executable()
	app := AppDefinition{
		ID: "fixture", Name: "Fixture", Icon: "F", Accent: "#2563eb",
		ProxyURL: "http://127.0.0.1:60000", Command: executable, Arguments: []string{}, StopArgs: []string{},
	}
	for _, proxyURL := range []string{"http://127.0.0.1:60000/base", "http://127.0.0.1:60000?x=1"} {
		invalid := app
		invalid.ProxyURL = proxyURL
		if err := node.validateRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{invalid}}); err == nil {
			t.Fatalf("proxy_url with path or query accepted: %q", proxyURL)
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

func TestDisabledApplicationNotProxied(t *testing.T) {
	executable, _ := os.Executable()
	port := testFreePort(t)
	listener, err := net.Listen("tcp4", "127.0.0.1:"+port)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	node, _ := initializeTestNode(t)
	app := AppDefinition{
		ID: "disabled", Name: "Disabled", Icon: "D", Accent: "#2563eb",
		ProxyURL: "http://127.0.0.1:" + port, Command: executable,
		Arguments: []string{}, StopArgs: []string{},
	}
	if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{app}}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(node.enabledPath(app.ID)); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Cookie", "RemoteEverythingApp=disabled")
	recorder := httptest.NewRecorder()
	node.gatewayHandler(recorder, request)
	if probeOpen("127.0.0.1:"+port) && !strings.Contains(recorder.Body.String(), "尚未选择远程应用") {
		t.Fatalf("disabled application with occupied port was proxied: %s", recorder.Body.String())
	}
}

func TestProxyStripsEveryInternalHeader(t *testing.T) {
	var received http.Header
	var receivedHost string
	application := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		received = request.Header.Clone()
		receivedHost = request.Host
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
	if err := os.WriteFile(node.enabledPath(app.ID), []byte("enabled\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Host = "gateway.example"
	request.Header.Set("Cookie", "RemoteEverythingApp=fixture")
	request.Header.Set("Authorization", "secret")
	request.Header.Set("X-Remote-Everything-Client-Fingerprint", strings.Repeat("ab", 32))
	request.Header.Set("X-Remote-Everything-Control-Token", "secret")
	recorder := httptest.NewRecorder()
	node.gatewayHandler(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Body.String() != "ok" {
		t.Fatalf("proxy response = %d %q", recorder.Code, recorder.Body.String())
	}
	for _, name := range []string{"X-Remote-Everything-Client-Fingerprint", "X-Remote-Everything-Control-Token"} {
		if received.Get(name) != "" {
			t.Fatalf("internal header leaked: %s", name)
		}
	}
	if received.Get("Authorization") != "secret" {
		t.Fatal("application authorization header lost")
	}
	if receivedHost != "gateway.example" {
		t.Fatalf("upstream Host should preserve the entrance host, got %q", receivedHost)
	}
}

// writeTestBundle writes the identity bundle a gateway side hands to a node,
// returning the bootstrap directory.
func writeTestBundle(t *testing.T, installationID, controlToken string) string {
	t.Helper()
	bootstrapDir := filepath.Join(t.TempDir(), "bootstrap")
	if err := deploymentbootstrap.WriteNodeBundle(bootstrapDir, installationID, controlToken); err != nil {
		t.Fatal(err)
	}
	return bootstrapDir
}

func TestControlRejectsTrailingJSON(t *testing.T) {
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	token := strings.Repeat("a", 64)
	if _, err := AddBinding(root, writeTestBundle(t, strings.Repeat("b", 64), token)); err != nil {
		t.Fatal(err)
	}
	node, err := Open(root, testPlatform{})
	if err != nil {
		t.Fatal(err)
	}
	accepted := httptest.NewRequest(http.MethodPost, "/__local_remote_control", bytes.NewBufferString(`{"action":"list"}`))
	accepted.Header.Set("Authorization", "Bearer "+token)
	acceptedRecorder := httptest.NewRecorder()
	node.localControlHandler(acceptedRecorder, accepted)
	if acceptedRecorder.Code != http.StatusOK || !strings.Contains(acceptedRecorder.Body.String(), `"ok":true`) {
		t.Fatalf("well-formed request status = %d body = %s", acceptedRecorder.Code, acceptedRecorder.Body.String())
	}
	request := httptest.NewRequest(http.MethodPost, "/__local_remote_control", bytes.NewBufferString(`{"action":"list"}{}`))
	request.Header.Set("Authorization", "Bearer "+token)
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

func TestAppListHidesAdapterSourceAndAdapterCommandShowsIt(t *testing.T) {
	node, _ := initializeTestNode(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	base := func(id, name string) AppDefinition {
		return AppDefinition{
			ID: id, Name: name, Icon: "F", Accent: "#2563eb", ProxyURL: "http://127.0.0.1:60000", Command: executable,
			Arguments: []string{}, StopArgs: []string{},
		}
	}
	adapted := base("dsh", "DSH")
	adapted.Adapter = "function onStart() {}\n"
	plain := base("plain", "Plain")
	if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{adapted, plain}}); err != nil {
		t.Fatal(err)
	}
	var listed bytes.Buffer
	if err := node.listRegistry(&listed); err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Schema int              `json:"schema"`
		Apps   []map[string]any `json:"apps"`
	}
	if err := json.Unmarshal(listed.Bytes(), &decoded); err != nil {
		t.Fatalf("app list output is not decodable: %v", err)
	}
	if len(decoded.Apps) != 2 || decoded.Apps[0]["name"] != "DSH" || decoded.Apps[1]["name"] != "Plain" {
		t.Fatalf("app list lost application metadata: %s", listed.String())
	}
	for _, app := range decoded.Apps {
		if _, present := app["adapter"]; present {
			t.Fatalf("app list exposed an adapter field: %s", listed.String())
		}
	}
	var source bytes.Buffer
	if err := node.showAdapter("dsh", &source); err != nil {
		t.Fatal(err)
	}
	if source.String() != adapted.Adapter {
		t.Fatalf("adapter source = %q, want %q", source.String(), adapted.Adapter)
	}
	if err := node.showAdapter("plain", &source); err == nil {
		t.Fatal("adapter command should fail for an application without an adapter")
	}
	if err := node.showAdapter("missing", &source); err == nil {
		t.Fatal("adapter command should fail for an unknown application")
	}
}

// A binding is the gateway's identity at the node and nothing more: the node
// keeps the control token it authenticates that gateway with, and no material
// belonging to anything the gateway owns.
func TestAddBindingRegistersIdentityOnly(t *testing.T) {
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	controlToken := strings.Repeat("a", 64)
	installationID := strings.Repeat("b", 64)
	result, err := AddBinding(root, writeTestBundle(t, installationID, controlToken))
	if err != nil {
		t.Fatal(err)
	}
	if result.InstallationID != installationID {
		t.Fatalf("expected installation_id %s, got %s", installationID, result.InstallationID)
	}
	bindingDir := filepath.Join(root, "bindings", installationID)
	entries, err := os.ReadDir(bindingDir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "control-token" {
		t.Fatalf("binding directory holds %v, want only control-token", entries)
	}
	state, err := LoadState(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Bindings) != 1 || state.Bindings[0].InstallationID != installationID {
		t.Fatalf("binding not in state: %+v", state.Bindings)
	}
}

func TestAddBindingIsIdempotent(t *testing.T) {
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	bootstrapDir := writeTestBundle(t, strings.Repeat("b", 64), strings.Repeat("a", 64))
	if _, err := AddBinding(root, bootstrapDir); err != nil {
		t.Fatal(err)
	}
	if _, err := AddBinding(root, bootstrapDir); err != nil {
		t.Fatalf("second AddBinding should be idempotent: %v", err)
	}
	state, _ := LoadState(root)
	if len(state.Bindings) != 1 {
		t.Fatalf("expected 1 binding, got %d", len(state.Bindings))
	}
}

// Re-binding an installation that is already bound with another token must fail
// rather than silently redefine which token that gateway authenticates with.
func TestAddBindingRejectsAnotherTokenForTheSameInstallation(t *testing.T) {
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	installationID := strings.Repeat("b", 64)
	if _, err := AddBinding(root, writeTestBundle(t, installationID, strings.Repeat("a", 64))); err != nil {
		t.Fatal(err)
	}
	if _, err := AddBinding(root, writeTestBundle(t, installationID, strings.Repeat("c", 64))); err == nil {
		t.Fatal("re-binding an installation with another control token was accepted")
	}
	token, err := os.ReadFile(filepath.Join(root, "bindings", installationID, "control-token"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(token)) != strings.Repeat("a", 64) {
		t.Fatalf("failed re-bind changed the bound token to %q", strings.TrimSpace(string(token)))
	}
}

func TestRemoveBindingDeletesMaterials(t *testing.T) {
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	installationID := strings.Repeat("b", 64)
	if _, err := AddBinding(root, writeTestBundle(t, installationID, strings.Repeat("a", 64))); err != nil {
		t.Fatal(err)
	}
	if err := RemoveBinding(root, installationID); err != nil {
		t.Fatal(err)
	}
	bindingDir := filepath.Join(root, "bindings", installationID)
	if _, err := os.Stat(bindingDir); !os.IsNotExist(err) {
		t.Fatalf("binding directory should be deleted")
	}
	state, _ := LoadState(root)
	if len(state.Bindings) != 0 {
		t.Fatalf("expected 0 bindings, got %d", len(state.Bindings))
	}
	// Idempotent: removing again should not error
	if err := RemoveBinding(root, installationID); err != nil {
		t.Fatalf("remove non-existent binding should be idempotent: %v", err)
	}
}

// Control auth follows the tokens bound on disk: with none bound every request
// is rejected, any bound gateway's token is accepted, a foreign token is not,
// and binding add/remove reach a running node without a restart. Asserted
// through the control endpoint's status codes, not the auth helper.
func TestControlAuthFollowsBoundTokens(t *testing.T) {
	root := t.TempDir()
	if _, err := Initialize(root); err != nil {
		t.Fatal(err)
	}
	node, err := Open(root, testPlatform{})
	if err != nil {
		t.Fatal(err)
	}
	status := func(token string) int {
		t.Helper()
		request := httptest.NewRequest(http.MethodPost, "/__local_remote_control", strings.NewReader(`{"action":"list"}`))
		request.Header.Set("Authorization", "Bearer "+token)
		recorder := httptest.NewRecorder()
		node.localControlHandler(recorder, request)
		return recorder.Code
	}

	controlToken1 := strings.Repeat("a", 64)
	installationID1 := strings.Repeat("b", 64)
	controlToken2 := strings.Repeat("c", 64)
	if code := status(controlToken1); code != http.StatusUnauthorized {
		t.Fatalf("status without bindings = %d", code)
	}
	for _, tc := range []struct{ control, install string }{
		{controlToken1, installationID1},
		{controlToken2, strings.Repeat("d", 64)},
	} {
		if _, err := AddBinding(root, writeTestBundle(t, tc.install, tc.control)); err != nil {
			t.Fatal(err)
		}
	}
	if code := status(controlToken1); code != http.StatusOK {
		t.Fatalf("status for a bound token = %d", code)
	}
	if code := status(controlToken2); code != http.StatusOK {
		t.Fatalf("status for a token bound after Open = %d", code)
	}
	if code := status(strings.Repeat("e", 64)); code != http.StatusUnauthorized {
		t.Fatalf("status for an unbound token = %d", code)
	}
	if err := RemoveBinding(root, installationID1); err != nil {
		t.Fatal(err)
	}
	if code := status(controlToken1); code != http.StatusUnauthorized {
		t.Fatalf("status for a removed binding = %d", code)
	}
	if code := status(controlToken2); code != http.StatusOK {
		t.Fatalf("status for the remaining binding = %d", code)
	}
}
