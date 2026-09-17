package devicecore

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

var (
	testNodeIDs    = [2]string{strings.Repeat("11", 32), strings.Repeat("22", 32)}
	testNodeTokens = [2]string{strings.Repeat("33", 32), strings.Repeat("44", 32)}
	testNodeNames  = [2]string{"Desk", "Laptop"}
)

// testNode is one machine behind a test gateway: it answers its control endpoint
// the way a node does, records what it was asked for, and can be taken away the
// way a machine that went down is.
type testNode struct {
	id     string
	token  string
	server *httptest.Server
	mutex  sync.Mutex
	down   bool
	seen   []string
}

func (node *testNode) setDown(down bool) {
	node.mutex.Lock()
	defer node.mutex.Unlock()
	node.down = down
}

func (node *testNode) record(what string) {
	node.mutex.Lock()
	defer node.mutex.Unlock()
	node.seen = append(node.seen, what)
}

// saw is every request this node was asked for, in order: a request the trust
// refused must never appear here.
func (node *testNode) saw() []string {
	node.mutex.Lock()
	defer node.mutex.Unlock()
	return append([]string{}, node.seen...)
}

func (node *testNode) serveHTTP(writer http.ResponseWriter, request *http.Request) {
	node.mutex.Lock()
	down := node.down
	node.mutex.Unlock()
	if down {
		writer.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	if request.URL.Path != proxysecurity.ControlPath {
		node.record(request.URL.Path)
		_, _ = io.WriteString(writer, "proxied")
		return
	}
	if request.Header.Get("Authorization") != "Bearer "+node.token {
		writer.WriteHeader(http.StatusUnauthorized)
		return
	}
	var command map[string]string
	_ = json.NewDecoder(request.Body).Decode(&command)
	node.record(command["action"] + "/" + command["id"])
	if command["action"] == "list" {
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"fixture","name":"Fixture","description":"","icon":"F","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
		return
	}
	_, _ = io.WriteString(writer, `{"ok":true,"action":"`+command["action"]+`","computer_connected":true,"enabled":true,"running":true,"code":"ready","app":{"id":"fixture","name":"Fixture","description":"","icon":"F","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}}`)
}

// gatewayFixture is a gateway and the device trust in front of it: two nodes, each
// a machine of its own with an identity and a control token of its own, so that a
// device granted one of them can be shown not to reach the other.
type gatewayFixture struct {
	root  string
	state gatewaycore.State
	nodes []*testNode
	trust *Trust
}

func newGatewayFixture(t *testing.T, approveOnRedemption bool) *gatewayFixture {
	t.Helper()
	fixture := &gatewayFixture{root: t.TempDir()}
	state, err := gatewaycore.NewState(strings.Repeat("aa", 32), "https://remote.example.com", []gatewaycore.Listener{{Name: "status", Address: "127.0.0.1:58629"}})
	if err != nil {
		t.Fatal(err)
	}
	for index, id := range testNodeIDs {
		node := &testNode{id: id, token: testNodeTokens[index]}
		node.server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			node.serveHTTP(writer, request)
		}))
		t.Cleanup(node.server.Close)
		tokenPath := gatewaycore.NodeTokenPath(fixture.root, id)
		if err := os.MkdirAll(filepath.Dir(tokenPath), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := atomicfile.Write(tokenPath, []byte(node.token+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		if state, err = state.AddNode(gatewaycore.Node{ID: id, Name: testNodeNames[index], Address: strings.TrimPrefix(node.server.URL, "http://")}); err != nil {
			t.Fatal(err)
		}
		fixture.nodes = append(fixture.nodes, node)
	}
	fixture.state = state
	gateway, err := gatewaycore.New(state, fixture.root)
	if err != nil {
		t.Fatal(err)
	}
	trust, err := Open(Config{
		Root: fixture.root, InstallationID: state.InstallationID, Origin: state.Origin,
		ApproveOnRedemption: approveOnRedemption, Node: gateway,
	})
	if err != nil {
		t.Fatal(err)
	}
	trust.pairFailureDelay = 0
	fixture.trust = trust
	return fixture
}

// nodeAt is the node behind this gateway that an invitation or a grant names.
func (fixture *gatewayFixture) nodeAt(index int) gatewaycore.Node {
	node, _ := fixture.state.FindNode(testNodeIDs[index])
	return node
}

// invite hands out an invitation for the node at index, and returns its token.
func (fixture *gatewayFixture) invite(t *testing.T, index int) string {
	t.Helper()
	var output strings.Builder
	if err := fixture.trust.issueInvitation(10*time.Minute, fixture.nodeAt(index), "Test PC", "", &output); err != nil {
		t.Fatal(err)
	}
	var result invitationResult
	if err := json.Unmarshal([]byte(output.String()), &result); err != nil {
		t.Fatal(err)
	}
	return result.Invitation
}

// pair redeems an invitation for the node at index, and returns what the device
// was given.
func (fixture *gatewayFixture) pair(t *testing.T, index int) pairResponse {
	t.Helper()
	recorder := pairInvitation(t, fixture.trust, fixture.invite(t, index), `{"device_name":"Test Phone","credential_password":"credential-password-123"}`)
	if recorder.Code != http.StatusOK {
		t.Fatalf("pairing failed: %d %s", recorder.Code, recorder.Body.String())
	}
	var paired pairResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &paired); err != nil {
		t.Fatal(err)
	}
	return paired
}

// activate asks for the node at index with this device's fingerprint, the way a
// client does: the request says which node it is for.
func (fixture *gatewayFixture) activate(fingerprint string, index int) (string, error) {
	request := httptest.NewRequest(http.MethodPost, "/__remote_everything_activate", nil)
	request.Header.Set(clientFingerprintHeader, fingerprint)
	request.Header.Set(proxysecurity.NodeHeader, testNodeIDs[index])
	_, code, err := fixture.trust.activateDevice(request)
	return code, err
}

// admit brings a paired device to the state its gateway admits it in: a gateway
// whose invitation is the approval admits it by activating, and one whose operator
// confirms devices needs that confirmation in between.
func (fixture *gatewayFixture) admit(t *testing.T, fingerprint string, index int) {
	t.Helper()
	code, err := fixture.activate(fingerprint, index)
	switch {
	case code == "" && err == nil:
		return
	case code == "approval_pending":
		if err := fixture.trust.deviceApprove(fingerprint, io.Discard); err != nil {
			t.Fatal(err)
		}
		if code, err = fixture.activate(fingerprint, index); code != "" || err != nil {
			t.Fatalf("approval did not admit the device: %s %v", code, err)
		}
	default:
		t.Fatalf("activation answered %s %v", code, err)
	}
}

// request sends one admitted request the way a client does, for one node.
func (fixture *gatewayFixture) request(method, path, fingerprint string, index int) *httptest.ResponseRecorder {
	return nodeRequest(fixture.trust, method, path, fingerprint, testNodeIDs[index])
}

// stubGateway is a gateway the trust can be opened against when a test is about
// the trust's own files rather than about what it fronts: one node that answers
// its control endpoint, at an address of its own.
func stubGateway(t *testing.T) *gatewaycore.Gateway {
	t.Helper()
	root := t.TempDir()
	node := &testNode{id: testNodeIDs[0], token: testNodeTokens[0]}
	node.server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		node.serveHTTP(writer, request)
	}))
	t.Cleanup(node.server.Close)
	if err := os.MkdirAll(filepath.Dir(gatewaycore.NodeTokenPath(root, node.id)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := atomicfile.Write(gatewaycore.NodeTokenPath(root, node.id), []byte(node.token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	state, err := gatewaycore.NewState(strings.Repeat("aa", 32), "https://remote.example.com", []gatewaycore.Listener{{Name: "status", Address: "127.0.0.1:58629"}})
	if err != nil {
		t.Fatal(err)
	}
	state, err = state.AddNode(gatewaycore.Node{ID: node.id, Name: testNodeNames[0], Address: strings.TrimPrefix(node.server.URL, "http://")})
	if err != nil {
		t.Fatal(err)
	}
	gateway, err := gatewaycore.New(state, root)
	if err != nil {
		t.Fatal(err)
	}
	return gateway
}

// nodeRequest is one request as a client sends it: the fingerprint of the
// certificate the entrance verified, and the node it is for.
func nodeRequest(service *Trust, method, path, fingerprint, nodeID string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, path, nil)
	if fingerprint != "" {
		request.Header.Set(clientFingerprintHeader, fingerprint)
	}
	if nodeID != "" {
		request.Header.Set(proxysecurity.NodeHeader, nodeID)
	}
	recorder := httptest.NewRecorder()
	service.statusHTTPHandler(recorder, request)
	return recorder
}

func pairInvitation(t *testing.T, service *Trust, invitation, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, pairRequestPath, strings.NewReader(body))
	request.Header.Set("Authorization", "Invitation "+invitation)
	recorder := httptest.NewRecorder()
	service.pairHTTPHandler(recorder, request)
	return recorder
}
