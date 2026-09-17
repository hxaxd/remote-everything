package gatewaycore

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

// The two nodes every test gateway serves: they have identities and control
// tokens of their own, so a gateway that reached one with the other's token, or
// answered for the wrong one, would show here.
var (
	testNodeIDs = [2]string{strings.Repeat("a1", 32), strings.Repeat("b2", 32)}
	testTokens  = [2]string{strings.Repeat("c3", 32), strings.Repeat("d4", 32)}
	testApps    = [2]string{"demo", "other"}
	testNames   = [2]string{"Desk", "Laptop"}
)

// nodeFixture is one machine a test gateway serves: it answers its control API the
// way a node does, records everything it was asked for, and answers the rest of
// its traffic as the application it runs.
type nodeFixture struct {
	id     string
	token  string
	server *httptest.Server
	app    http.HandlerFunc
	mutex  sync.Mutex
	seen   []string
}

// cluster is the machines a test gateway serves.
type cluster struct {
	nodes []*nodeFixture
}

func (fixture *nodeFixture) record(what string) {
	fixture.mutex.Lock()
	defer fixture.mutex.Unlock()
	fixture.seen = append(fixture.seen, what)
}

// saw is every request this node was asked for, in order: a request the gateway
// refused must never appear here.
func (fixture *nodeFixture) saw() []string {
	fixture.mutex.Lock()
	defer fixture.mutex.Unlock()
	return append([]string{}, fixture.seen...)
}

func (cluster *cluster) id(index int) string    { return cluster.nodes[index].id }
func (cluster *cluster) saw(index int) []string { return cluster.nodes[index].saw() }

func (fixture *nodeFixture) serveHTTP(t *testing.T, index int, writer http.ResponseWriter, request *http.Request) {
	if request.URL.Path == "/__local_remote_control" {
		if request.Header.Get("Authorization") != "Bearer "+fixture.token {
			t.Errorf("node %s was asked without its own control token", fixture.id)
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		var command map[string]string
		if err := json.NewDecoder(request.Body).Decode(&command); err != nil {
			t.Error(err)
			return
		}
		fixture.record(command["action"] + "/" + command["id"])
		if command["action"] == "list" {
			apps := []ApplicationState{{ID: testApps[index], Name: "Demo", Description: "", Icon: "D", Accent: "#2563eb", ComputerConnected: true, Enabled: true, Running: true, Code: "ready"}}
			WriteJSON(writer, http.StatusOK, ControlResponse{OK: true, ComputerConnected: true, Code: "ready", Apps: apps})
			return
		}
		WriteJSON(writer, http.StatusOK, map[string]any{"ok": true, "action": command["action"], "computer_connected": true, "enabled": true, "running": true, "code": "ready"})
		return
	}
	fixture.record(request.URL.Path)
	fixture.app(writer, request)
}

// newTestGateway builds a gateway that serves two nodes, each of them a machine of
// its own at the address its state recorded and authenticating with its own token.
// Every node answers its application with handler.
func newTestGateway(t *testing.T, handler http.HandlerFunc) (*Gateway, *cluster) {
	t.Helper()
	if handler == nil {
		handler = func(writer http.ResponseWriter, request *http.Request) {
			WriteJSON(writer, http.StatusOK, map[string]bool{"proxied": true})
		}
	}
	built := &cluster{}
	root := t.TempDir()
	state, err := NewState(strings.Repeat("f0", 32), "https://gateway.example", []Listener{{Name: "lan", Address: "127.0.0.1:58626"}})
	if err != nil {
		t.Fatal(err)
	}
	for index := range testNodeIDs {
		fixture := &nodeFixture{id: testNodeIDs[index], token: testTokens[index], app: handler}
		fixture.server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			fixture.serveHTTP(t, index, writer, request)
		}))
		t.Cleanup(fixture.server.Close)
		if err := os.MkdirAll(NodeTokenPath(root, fixture.id), 0o700); err != nil {
			t.Fatal(err)
		}
		tokenPath := NodeTokenPath(root, fixture.id)
		if err := os.RemoveAll(tokenPath); err != nil {
			t.Fatal(err)
		}
		if err := atomicfile.Write(tokenPath, []byte(fixture.token+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		state, err = state.AddNode(Node{ID: fixture.id, Name: testNames[index], Address: strings.TrimPrefix(fixture.server.URL, "http://")})
		if err != nil {
			t.Fatal(err)
		}
		built.nodes = append(built.nodes, fixture)
	}
	gateway, err := New(state, root)
	if err != nil {
		t.Fatal(err)
	}
	return gateway, built
}

// ask sends one request for the node with this id, the way the trust does once it
// has decided which node a request is for.
func ask(gateway *Gateway, nodeID, method, target string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, target, nil)
	response := httptest.NewRecorder()
	gateway.ServeNode(nodeID, response, request)
	return response
}

// Every request says which node it is for, and that is where it goes: a gateway
// that answered one node's request with another's catalog, or that sent it to
// every node, would show here.
func TestEachRequestGoesToTheNodeItNames(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	for index := range cluster.nodes {
		other := 1 - index
		before := len(cluster.saw(other))
		response := ask(gateway, cluster.id(index), http.MethodGet, "/__remote_everything/apps")
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"id":"`+testApps[index]+`"`) {
			t.Fatalf("node %d answered its catalog with %d %s", index, response.Code, response.Body.String())
		}
		if saw := cluster.saw(index); len(saw) != 1 || saw[0] != "list/" {
			t.Fatalf("node %d was asked for %v", index, saw)
		}
		if saw := cluster.saw(other); len(saw) != before {
			t.Fatalf("node %d was asked for the request another node was named in: %v", other, saw)
		}
	}
}

// A node this gateway does not serve has no route here, and is not guessed at: no
// other node is asked instead. Which nodes a request may name at all is decided
// where the permission is, before the gateway is asked for one.
func TestARequestForNoKnownNodeIsRefused(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	for _, nodeID := range []string{"", strings.Repeat("ee", 32), strings.Repeat("a1", 32) + "x"} {
		response := ask(gateway, nodeID, http.MethodGet, "/__remote_everything/apps")
		if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `"node_not_found"`) {
			t.Fatalf("a request naming %q was answered with %d %s", nodeID, response.Code, response.Body.String())
		}
	}
	for index := range cluster.nodes {
		if saw := cluster.saw(index); len(saw) != 0 {
			t.Fatalf("node %d answered a request that named no node: %v", index, saw)
		}
	}
}

// A gateway with nothing behind it is refused where it is opened rather than
// starting and answering nothing.
func TestNewRefusesAGatewayThatServesNoNode(t *testing.T) {
	state, err := NewState(strings.Repeat("f0", 32), "https://gateway.example", []Listener{{Name: "lan", Address: "127.0.0.1:58626"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := New(state, t.TempDir()); err == nil {
		t.Fatal("a gateway with no node was opened")
	}
}

// A node's control plane is the gateway's own way in, with the token it holds for
// that node, and it never travels through the proxy that serves the node's
// applications: a request for it is refused here, and the node is not asked.
func TestTheControlPlaneIsNeverProxied(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	for _, path := range []string{proxysecurity.ControlPath, "/%5f%5flocal_remote_control"} {
		if response := ask(gateway, cluster.id(0), http.MethodGet, path); response.Code != http.StatusForbidden {
			t.Fatalf("%s was answered with %d %s", path, response.Code, response.Body.String())
		}
	}
	for index := range cluster.nodes {
		if saw := cluster.saw(index); len(saw) != 0 {
			t.Fatalf("node %d was asked for its own control plane through the proxy: %v", index, saw)
		}
	}
}

func TestConnectedListRejectsUnknownAndInconsistentNodeCatalogs(t *testing.T) {
	for _, body := range []string{
		`{"ok":true,"computer_connected":true,"code":"ready","apps":[],"legacy":true}`,
		`{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"demo","name":"Demo","description":"","icon":"D","accent":"#2563eb","computer_connected":true,"enabled":false,"running":false,"code":"ready"}]}`,
	} {
		node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) { _, _ = writer.Write([]byte(body)) }))
		root := t.TempDir()
		state, err := NewState(strings.Repeat("f0", 32), "https://gateway.example", []Listener{{Name: "lan", Address: "127.0.0.1:58626"}})
		if err != nil {
			t.Fatal(err)
		}
		state, err = state.AddNode(Node{ID: testNodeIDs[0], Name: testNames[0], Address: strings.TrimPrefix(node.URL, "http://")})
		if err != nil {
			t.Fatal(err)
		}
		if err := recordNodeToken(t, root, testNodeIDs[0], testTokens[0]); err != nil {
			t.Fatal(err)
		}
		gateway, err := New(state, root)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := gateway.ConnectedList(testNodeIDs[0]); ok {
			t.Fatalf("accepted malformed node catalog: %s", body)
		}
		if _, ok := gateway.ConnectedList(strings.Repeat("ee", 32)); ok {
			t.Fatal("a node this gateway does not serve answered")
		}
		node.Close()
	}
}

// A node that cannot be reached says so the same way whichever endpoint is asked:
// a client reading the catalog and a client asking for an action see one offline
// answer, not two.
func TestOfflineAnswerIsTheSameOnEveryEndpoint(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	nodeID := cluster.id(0)
	cluster.nodes[0].server.Close()
	response := ask(gateway, nodeID, http.MethodGet, "/__remote_everything/apps")
	if response.Body.String() != `{"ok":true,"computer_connected":false,"code":"computer_offline","apps":[]}` {
		t.Fatalf("unexpected offline catalog: %s", response.Body.String())
	}
	response = ask(gateway, nodeID, http.MethodPost, "/__remote_everything/apps/"+testApps[0]+"/start")
	if response.Body.String() != `{"ok":false,"action":"start","computer_connected":false,"enabled":false,"running":false,"code":"computer_offline"}` {
		t.Fatalf("unexpected offline action: %s", response.Body.String())
	}
}

// Every control endpoint a client has is answered by the node in the order it was
// asked, so a gateway that reordered or dropped one would show here.
func TestClientRequestsReachTheNodeInOrder(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	nodeID := cluster.id(0)
	for _, asked := range []struct{ method, target string }{
		{http.MethodGet, "/__remote_everything/apps"},
		{http.MethodGet, "/__remote_everything/apps/" + testApps[0] + "/status"},
		{http.MethodPost, "/__remote_everything/apps/" + testApps[0] + "/start"},
	} {
		response := ask(gateway, nodeID, asked.method, asked.target)
		if response.Code != http.StatusOK {
			t.Fatalf("%s %s: %d %s", asked.method, asked.target, response.Code, response.Body.String())
		}
	}
	if saw := strings.Join(cluster.saw(0), ","); saw != "list/,status/"+testApps[0]+",start/"+testApps[0] {
		t.Fatalf("the node was asked for %v", saw)
	}
	if saw := cluster.saw(1); len(saw) != 0 {
		t.Fatalf("the other node was asked too: %v", saw)
	}
}

// Where a node is has to be a concrete address a gateway can dial, and its token
// has to be there: a name or an unspecified address gives the gateway nothing to
// connect to, and a token this gateway did not mint authenticates nothing.
func TestNewRefusesNodesItCannotReach(t *testing.T) {
	state, root := nodeStateAt(t, "192.168.1.10:58627", testTokens[0])
	if _, err := New(state, root); err != nil {
		t.Fatalf("a node on the network was refused: %v", err)
	}
	// Whatever a state says a node's address is, what the gateway dials has to be
	// a concrete address: a name or an address that means every machine on it is
	// not something to connect to.
	for _, address := range []string{"example.com:1234", "0.0.0.0:1234", "192.168.1.10"} {
		state, root := nodeStateAt(t, "192.168.1.10:58627", testTokens[0])
		state.Nodes[0].Address = address
		if _, err := New(state, root); err == nil {
			t.Fatalf("node address %q was dialed", address)
		}
	}
	state, root = nodeStateAt(t, "192.168.1.10:58627", "weak")
	if _, err := New(state, root); err == nil {
		t.Fatal("an invalid control token was accepted")
	}
	state, root = nodeStateAt(t, "192.168.1.10:58627", testTokens[0])
	if err := os.Remove(NodeTokenPath(root, testNodeIDs[0])); err != nil {
		t.Fatal(err)
	}
	if _, err := New(state, root); err == nil {
		t.Fatal("a node whose token is missing was accepted")
	}
}

func TestCatalogActionAndOpenContract(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	nodeID := cluster.id(0)
	for _, request := range []struct{ method, target string }{
		{http.MethodGet, "/__remote_everything/apps"},
		{http.MethodPost, "/__remote_everything/apps/" + testApps[0] + "/start"},
	} {
		response := ask(gateway, nodeID, request.method, request.target)
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"computer_connected":true`) {
			t.Fatalf("unexpected API response: %d %s", response.Code, response.Body.String())
		}
		if response.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Fatalf("writeRaw missing nosniff on %s: %#v", request.target, response.Header())
		}
	}

	response := ask(gateway, nodeID, http.MethodGet, "/__remote_everything/open/"+testApps[0])
	if response.Code != http.StatusFound || response.Header().Get("Location") != "/" {
		t.Fatalf("unexpected open response: %d", response.Code)
	}
	cookies := response.Result().Cookies()
	if len(cookies) != 1 || cookies[0].Name != "RemoteEverythingApp" || cookies[0].Value != testApps[0] || !cookies[0].Secure || !cookies[0].HttpOnly {
		t.Fatalf("unexpected application cookie: %#v", cookies)
	}
	if saw := cluster.saw(1); len(saw) != 0 {
		t.Fatalf("the other node was asked too: %v", saw)
	}
}

func TestProxyPreservesRequestAndStripsInternalHeaders(t *testing.T) {
	var (
		mutex        sync.Mutex
		capturedHost string
	)
	gateway, cluster := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {
		mutex.Lock()
		capturedHost = request.Host
		mutex.Unlock()
		if request.URL.Path != "/room/ws" || request.URL.RawQuery != "a=1" {
			t.Errorf("request target changed: path=%q query=%q", request.URL.Path, request.URL.RawQuery)
		}
		if request.Header.Get("Cookie") != "session=value" || request.Header.Get("Upgrade") != "websocket" {
			t.Errorf("cookie or upgrade header lost")
		}
		if request.Header.Get("Authorization") != "secret" {
			t.Errorf("application authorization header lost")
		}
		for _, name := range []string{proxysecurity.ClientFingerprintHeader, proxysecurity.NodeHeader} {
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
	request.Header.Set(proxysecurity.ClientFingerprintHeader, "secret")
	request.Header.Set(proxysecurity.NodeHeader, cluster.id(0))
	response := httptest.NewRecorder()
	gateway.ServeNode(cluster.id(0), response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("unexpected proxy response: %d %s", response.Code, response.Body.String())
	}
	mutex.Lock()
	defer mutex.Unlock()
	if capturedHost != "gateway.example" {
		t.Errorf("upstream Host should preserve the public entrance host, got %q", capturedHost)
	}
	cookies := response.Header().Values("Set-Cookie")
	if len(cookies) != 1 || !strings.HasPrefix(cookies[0], "session=value") {
		t.Fatalf("application could overwrite routing cookie or its own cookie was lost: %#v", cookies)
	}
}

// The nodes a gateway serves are what an operator adds devices to, so it reports
// them in the order they were added, with the id a request names them by.
func TestNodesAreWhatTheStateRecorded(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	nodes := gateway.Nodes()
	if len(nodes) != len(cluster.nodes) {
		t.Fatalf("gateway serves %d nodes, want %d", len(nodes), len(cluster.nodes))
	}
	for index, node := range nodes {
		if node.ID != cluster.id(index) || node.Name != testNames[index] || node.Address == "" {
			t.Fatalf("node %d is %+v", index, node)
		}
	}
	nodes[0].Name = "changed"
	if gateway.Nodes()[0].Name != testNames[0] {
		t.Fatal("the node list is the gateway's own, and was changed through the caller's copy")
	}
}

// nodeStateAt is a gateway state that serves one node at address, with its control
// token written for it the way the gateway writes one.
func nodeStateAt(t *testing.T, address, token string) (State, string) {
	t.Helper()
	root := t.TempDir()
	state, err := NewState(strings.Repeat("f0", 32), "https://gateway.example", []Listener{{Name: "lan", Address: "127.0.0.1:58626"}})
	if err != nil {
		t.Fatal(err)
	}
	state, err = state.AddNode(Node{ID: testNodeIDs[0], Name: testNames[0], Address: address})
	if err != nil {
		return State{}, ""
	}
	if err := recordNodeToken(t, root, testNodeIDs[0], token); err != nil {
		t.Fatal(err)
	}
	return state, root
}

func recordNodeToken(t *testing.T, root, nodeID, token string) error {
	t.Helper()
	path := NodeTokenPath(root, nodeID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return atomicfile.Write(path, []byte(token+"\n"), 0o600)
}
