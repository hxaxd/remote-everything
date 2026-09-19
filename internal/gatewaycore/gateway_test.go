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
	"github.com/hxaxd/remote-everything/internal/wire"
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
			apps := []wire.ApplicationState{{ID: testApps[index], Name: "Demo", Description: "", Icon: "D", Accent: "#2563eb", ComputerConnected: true, Enabled: true, Running: true, Code: "ready"}}
			WriteJSON(writer, http.StatusOK, wire.Catalog{OK: true, ComputerConnected: true, Code: "ready", Apps: apps})
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

// askApplication sends one request on an application's own origin, the way the
// gateway is asked for one once the origin was resolved and the device's reach was
// checked.
func askApplication(gateway *Gateway, nodeID, appID, method, target string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, target, nil)
	response := httptest.NewRecorder()
	gateway.ServeApplication(nodeID, appID, response, request)
	return response
}

// appHost is where one application of one node is served on the test gateway's
// domain: what a client that opened an application is sent to, and what a request
// on an application origin arrives with.
func appHost(t *testing.T, index int, appID string) (string, string) {
	t.Helper()
	host, err := AppHost(testNodeIDs[index], appID, "gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	return host, "https://" + host
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

	// Opening an application is answered with an absolute address of that
	// application's own, and with nothing a client would carry back here: the
	// origin says which application is being looked at, so no cookie says it.
	host, origin := appHost(t, 0, testApps[0])
	if host == "" || !strings.HasPrefix(origin, "https://"+testApps[0]+".") {
		t.Fatalf("application %s is served at %q", testApps[0], origin)
	}
	response := ask(gateway, nodeID, http.MethodGet, "/__remote_everything/open/"+testApps[0])
	if response.Code != http.StatusFound || response.Header().Get("Location") != origin+"/" || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("unexpected open response: %d %#v", response.Code, response.Header())
	}
	if cookies := response.Result().Cookies(); len(cookies) != 0 {
		t.Fatalf("opening an application set cookies: %#v", cookies)
	}
	// The same application comes back to the same origin however often it is
	// opened: that is what its browser storage belongs to.
	if again := ask(gateway, nodeID, http.MethodGet, "/__remote_everything/open/"+testApps[0]); again.Header().Get("Location") != origin+"/" {
		t.Fatalf("opening an application twice moved it: %q", again.Header().Get("Location"))
	}
	// An application this node does not run is not opened at any origin.
	if missing := ask(gateway, nodeID, http.MethodGet, "/__remote_everything/open/missing"); missing.Code != http.StatusNotFound || !strings.Contains(missing.Body.String(), `"app_not_found"`) {
		t.Fatalf("an application that does not exist answered %d %s", missing.Code, missing.Body.String())
	}
	if saw := cluster.saw(1); len(saw) != 0 {
		t.Fatalf("the other node was asked too: %v", saw)
	}
}

// An application is served at an origin of its own, which is where the gateway
// says which application a request is for: what the client claims under the same
// name is a choice the client made, and a client does not get to make it. The
// application's own request and answer are otherwise untouched.
func TestApplicationProxyPreservesRequestAndStripsInternalHeaders(t *testing.T) {
	var (
		mutex          sync.Mutex
		capturedHost   string
		capturedCookie string
	)
	gateway, cluster := newTestGateway(t, func(writer http.ResponseWriter, request *http.Request) {
		mutex.Lock()
		capturedHost = request.Host
		capturedCookie = request.Header.Get("Cookie")
		mutex.Unlock()
		if request.URL.Path != "/room/ws" || request.URL.RawQuery != "a=1" {
			t.Errorf("request target changed: path=%q query=%q", request.URL.Path, request.URL.RawQuery)
		}
		if request.Header.Get("Upgrade") != "websocket" {
			t.Errorf("upgrade header lost")
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
	host, origin := appHost(t, 0, testApps[0])
	request := httptest.NewRequest(http.MethodGet, origin+"/room/ws?a=1", nil)
	request.Host = host
	request.Header.Set("Cookie", "session=value; RemoteEverythingApp="+testApps[1])
	request.Header.Set("Upgrade", "websocket")
	request.Header.Set("Connection", "Upgrade")
	request.Header.Set("Authorization", "secret")
	request.Header.Set(proxysecurity.ClientFingerprintHeader, "secret")
	request.Header.Set(proxysecurity.NodeHeader, cluster.id(0))
	response := httptest.NewRecorder()
	gateway.ServeApplication(cluster.id(0), testApps[0], response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("unexpected proxy response: %d %s", response.Code, response.Body.String())
	}
	mutex.Lock()
	defer mutex.Unlock()
	if capturedHost != host {
		t.Errorf("upstream Host should preserve the application origin host, got %q", capturedHost)
	}
	if !strings.Contains(capturedCookie, "session=value") || !strings.Contains(capturedCookie, proxysecurity.RoutingCookieName+"="+testApps[0]) {
		t.Errorf("the node was told %q", capturedCookie)
	}
	if strings.Contains(capturedCookie, testApps[1]) {
		t.Errorf("the application the client claimed was passed on: %q", capturedCookie)
	}
	cookies := response.Header().Values("Set-Cookie")
	if len(cookies) != 1 || !strings.HasPrefix(cookies[0], "session=value") {
		t.Fatalf("application could overwrite routing cookie or its own cookie was lost: %#v", cookies)
	}
}

// An application path on the control origin is not served there: application
// traffic belongs to the application's own origin, and the control origin carries
// the protocol and nothing else.
func TestTheControlOriginServesNoApplication(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	for _, path := range []string{"/", "/editor/", "/room/ws"} {
		response := ask(gateway, cluster.id(0), http.MethodGet, path)
		if response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `"not_found"`) {
			t.Fatalf("%s on the control origin answered %d %s", path, response.Code, response.Body.String())
		}
	}
	for index := range cluster.nodes {
		if saw := cluster.saw(index); len(saw) != 0 {
			t.Fatalf("node %d answered a request on the control origin: %v", index, saw)
		}
	}
}

// A node's control plane is the gateway's own way in, and the protocol's paths are
// the protocol's: an origin that serves an application serves that application and
// nothing else, whatever the node behind it would answer.
func TestAnApplicationOriginServesNothingElse(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	_, origin := appHost(t, 0, testApps[0])
	for _, asked := range []struct {
		path string
		code int
		body string
	}{
		{proxysecurity.ControlPath, http.StatusForbidden, `"forbidden"`},
		{"/%5f%5flocal_remote_control", http.StatusForbidden, `"forbidden"`},
		{"/__remote_everything/nodes", http.StatusNotFound, `"not_found"`},
		{"/__remote_everything/apps", http.StatusNotFound, `"not_found"`},
	} {
		request := httptest.NewRequest(http.MethodGet, origin+asked.path, nil)
		response := httptest.NewRecorder()
		gateway.ServeApplication(cluster.id(0), testApps[0], response, request)
		if response.Code != asked.code || !strings.Contains(response.Body.String(), asked.body) {
			t.Fatalf("%s on an application origin answered %d %s", asked.path, response.Code, response.Body.String())
		}
	}
	// An application origin of a node this gateway does not serve, and one that
	// names an application that is not an id at all, have nothing to route.
	if response := askApplication(gateway, strings.Repeat("ee", 32), testApps[0], http.MethodGet, origin+"/"); response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `"node_not_found"`) {
		t.Fatalf("an application origin of an unknown node answered %d %s", response.Code, response.Body.String())
	}
	if response := askApplication(gateway, cluster.id(0), "Not An Id", http.MethodGet, origin+"/"); response.Code != http.StatusNotFound || !strings.Contains(response.Body.String(), `"app_not_found"`) {
		t.Fatalf("an application origin naming no application answered %d %s", response.Code, response.Body.String())
	}
	for index := range cluster.nodes {
		if saw := cluster.saw(index); len(saw) != 0 {
			t.Fatalf("node %d answered a request it was not asked: %v", index, saw)
		}
	}
}

// Which origin an application is served at is the shape's to say, and what it says
// is what a client is sent to: an entrance that serves its applications somewhere
// else tells the gateway so rather than the gateway guessing.
func TestOpeningAnApplicationAnswersWhereTheShapeServesIt(t *testing.T) {
	gateway, cluster := newTestGateway(t, nil)
	gateway.SetAppAddressing(stubAddressing{origin: "https://192.0.2.10:41000"})
	response := ask(gateway, cluster.id(0), http.MethodGet, "/__remote_everything/open/"+testApps[0])
	if response.Code != http.StatusFound || response.Header().Get("Location") != "https://192.0.2.10:41000/" {
		t.Fatalf("unexpected open response: %d %#v", response.Code, response.Header())
	}
}

// stubAddressing is one shape's answer to where its applications are served: one
// origin for every application, which is all this test needs to see be used.
type stubAddressing struct{ origin string }

func (addressing stubAddressing) Origin(string, string) (string, error) {
	return addressing.origin, nil
}

// An application host carries the node it belongs to and the application itself,
// and it is read back the same way: what it does not name is not an application
// host at all, since a host that names none is not one a gateway can route.
func TestApplicationHostsNameOneNodeAndOneApplication(t *testing.T) {
	host, err := AppHost(testNodeIDs[0], "demo", "Gateway.Example")
	if err != nil || host != "demo.a1a1a1a1.gateway.example" {
		t.Fatalf("an application host is %q (%v)", host, err)
	}
	// A host is not case sensitive and may carry the port of the origin it is
	// dialled at: both are the same host, and they name the same application.
	for _, accepted := range []struct{ host, node, app string }{
		{"demo.a1a1a1a1.gateway.example", testNodeIDs[0], "demo"},
		{"demo.a1a1a1a1.GATEWAY.Example:443", testNodeIDs[0], "demo"},
		{"other.b2b2b2b2.gateway.example.", testNodeIDs[1], "other"},
	} {
		prefix, appID, ok := ParseAppHost(accepted.host, "gateway.example")
		if !ok || prefix != accepted.node[:8] || appID != accepted.app {
			t.Fatalf("%q parsed as %q %q %v", accepted.host, prefix, appID, ok)
		}
	}
	for _, refused := range []string{
		"",                                    // no host at all
		"a1a1a1a1.gateway.example",            // no application
		"demo.gateway.example",                // no node
		"demo.a1a1a1.gateway.example",         // a prefix that is not eight characters
		"demo.a1a1a1a1g.gateway.example",      // a prefix that is not hex
		"demo.a1a1a1a1.other.example",         // another gateway's domain
		"demo.a1a1a1a1",                       // no domain
		"demo.a1a1a1a1.gateway.example.extra", // one label too many
		"de mo.a1a1a1a1.gateway.example",      // not a host
	} {
		if prefix, appID, ok := ParseAppHost(refused, "gateway.example"); ok {
			t.Fatalf("%q parsed as %q %q", refused, prefix, appID)
		}
	}
	for _, refused := range []struct{ nodeID, appID, domain string }{
		{testNodeIDs[0], "Demo", "gateway.example"},
		{testNodeIDs[0], "", "gateway.example"},
		{strings.Repeat("a1", 31), "demo", "gateway.example"},
		{testNodeIDs[0], "demo", "gateway.example:443"},
		{testNodeIDs[0], "demo", ""},
	} {
		if host, err := AppHost(refused.nodeID, refused.appID, refused.domain); err == nil {
			t.Fatalf("an application host was built as %q", host)
		}
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

// What an application's request carries is the application's: the router's own
// cookie is set, and every other cookie is handed on exactly as it arrived —
// including one that was quoted, which parsing and re-writing it would change.
func TestAnApplicationRequestKeepsTheCookiesItCarried(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Cookie", `session=abc123; token="quoted value"; flag`)
	setRoutingCookie(request, "editor")
	carried := request.Header.Get("Cookie")
	for _, wanted := range []string{`session=abc123`, `token="quoted value"`, `flag`, proxysecurity.RoutingCookieName + "=editor"} {
		if !strings.Contains(carried, wanted) {
			t.Fatalf("the request carries %q, which does not hold %q", carried, wanted)
		}
	}
}

// A client cannot choose the application it is served: a cookie of the routing
// name it sent is dropped, and the one the gateway set is what arrives.
func TestAClientCannotChooseAnApplicationItIsServed(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.Header.Set("Cookie", proxysecurity.RoutingCookieName+"=something-else")
	setRoutingCookie(request, "editor")
	if carried := request.Header.Get("Cookie"); strings.Contains(carried, "something-else") {
		t.Fatalf("the request carries %q", carried)
	}
}
