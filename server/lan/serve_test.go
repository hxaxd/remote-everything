package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/hxaxd/remote-everything/internal/backplane/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/gateway/entrance"
	"github.com/hxaxd/remote-everything/internal/gateway/entrancetest"
	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/infra/netaddr"
	"github.com/hxaxd/remote-everything/internal/node/nodecore"
)

// A LAN entrance is a gateway shape, so its behaviour is the shared one: what it
// adds here is only how its clients reach it, which is over the TLS it terminates
// itself with the certificate they pinned, and how it reaches its nodes, which is
// each machine's own address on the network.
func TestLANEntranceBehaviour(t *testing.T) {
	entrancetest.Run(t, startLANEntrance(t))
}

// lanHarness is the LAN entrance as the shared suite sees it, with the two
// machines behind it.
type lanHarness struct {
	service      *lanService
	origin       string
	pinned       *x509.Certificate
	mutex        sync.Mutex
	nodeRequests map[string][]string
}

func startLANEntrance(t *testing.T, opts ...LANInitOption) *lanHarness {
	t.Helper()
	harness := &lanHarness{nodeRequests: map[string][]string{}}
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", "", 30, opts...); err != nil {
		t.Fatal(err)
	}
	// Each node is a machine of its own, at the address this entrance records for
	// it: that address is what the entrance dials, and what a request for that node
	// arrives at.
	for index, id := range entrancetest.NodeIDs {
		address := harness.startNode(t, id)
		bundle := filepath.Join(t.TempDir(), "bootstrap")
		if _, err := addLANNode(root, entrancetest.NodeNames[index], id, address, "", bundle); err != nil {
			t.Fatal(err)
		}
	}
	service, err := openLANService(root)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := loadLANCertificate(root, service.state)
	if err != nil {
		t.Fatal(err)
	}
	surfaces, err := service.Surfaces()
	if err != nil {
		t.Fatal(err)
	}
	// A deployment binds every address its state recorded; a test binds the
	// entrance's own surface on a port of its own so two entrances never collide,
	// and serves the same surface on it. An application's surface is bound where the
	// state says, because that address is the origin the application is served at.
	for index, surface := range surfaces {
		address := surface.Address
		if index == 0 {
			address = "127.0.0.1:0"
		}
		listener, listenErr := net.Listen("tcp", address)
		if listenErr != nil {
			t.Fatal(listenErr)
		}
		go func(surface entrance.Surface, listener net.Listener) { _ = surface.Bind(listener) }(surface, listener)
		t.Cleanup(func() { _ = listener.Close() })
		if index == 0 {
			harness.origin = "https://" + listener.Addr().String()
		}
	}

	harness.service = service
	harness.pinned = certificate
	return harness
}

// startNode stands up one machine behind this entrance, answering its control
// endpoint the way a node does and recording everything it was asked for.
func (harness *lanHarness) startNode(t *testing.T, id string) string {
	t.Helper()
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		harness.mutex.Lock()
		harness.nodeRequests[id] = append(harness.nodeRequests[id], request.URL.Path)
		harness.mutex.Unlock()
		writer.Header().Set("Content-Type", "application/json")
		if request.URL.Path != "/__local_remote_control" {
			_, _ = io.WriteString(writer, `{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}`)
			return
		}
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
	}))
	t.Cleanup(node.Close)
	return strings.TrimPrefix(node.URL, "http://")
}

func (harness *lanHarness) Gateway() entrance.Gateway { return harness.service }

func (harness *lanHarness) Dial(credential *tls.Certificate, method, path string, header map[string]string, body []byte) (int, string, error) {
	response, contents, err := harness.request(credential, harness.origin, method, path, header, body)
	if err != nil {
		return 0, "", err
	}
	return response.StatusCode, string(contents), nil
}

// Open asks this entrance to open one application, which is a request on the
// entrance itself with the node it is for: what comes back is the application's own
// origin, and that is where the application is reached.
func (harness *lanHarness) Open(credential *tls.Certificate, node gatewaycore.Node, appID string) (int, string, error) {
	header := map[string]string{proxysecurity.NodeHeader: node.ID}
	response, _, err := harness.request(credential, harness.origin, http.MethodGet, "/__remote_everything/open/"+appID, header, nil)
	if err != nil {
		return 0, "", err
	}
	return response.StatusCode, response.Header.Get("Location"), nil
}

// DialApplication sends one request to one application's own origin, which this
// entrance serves on a port of its own: the origin is allocated for the
// application here the way opening it allocates one.
func (harness *lanHarness) DialApplication(credential *tls.Certificate, node gatewaycore.Node, appID, method, path string, header map[string]string, body []byte) (int, string, error) {
	origin, err := harness.service.Origin(node.ID, appID)
	if err != nil {
		return 0, "", err
	}
	response, contents, err := harness.request(credential, origin, method, path, header, body)
	if err != nil {
		return 0, "", err
	}
	return response.StatusCode, string(contents), nil
}

// request sends one request over the TLS this entrance terminates, with the
// certificate its clients pinned as the only authority this client trusts and the
// credential of the device that is asking.
func (harness *lanHarness) request(credential *tls.Certificate, origin, method, path string, header map[string]string, body []byte) (*http.Response, []byte, error) {
	configuration := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: x509.NewCertPool()}
	configuration.RootCAs.AddCert(harness.pinned)
	if credential != nil {
		configuration.Certificates = []tls.Certificate{*credential}
	}
	client := &http.Client{
		Transport: &http.Transport{TLSClientConfig: configuration},
		// Opening an application is answered with the application's own origin, and
		// that answer is what these requests are about: a client that followed it
		// would be testing the application rather than the redirect.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	request, err := http.NewRequest(method, origin+path, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	for name, value := range header {
		request.Header.Set(name, value)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	contents, _ := io.ReadAll(response.Body)
	return response, contents, nil
}

func (harness *lanHarness) ApprovesInline() bool { return !harness.service.state.RequireApproval }

func (harness *lanHarness) Approve(fingerprint string) error {
	var out bytes.Buffer
	return harness.service.trust.RunCLI([]string{"approve", fingerprint}, &out)
}

func TestLANEntranceBehaviourWithRequireApproval(t *testing.T) {
	entrancetest.Run(t, startLANEntrance(t, WithRequireApproval(true)))
}

func (harness *lanHarness) NodeSaw(nodeID string) []string {
	harness.mutex.Lock()
	defer harness.mutex.Unlock()
	return append([]string{}, harness.nodeRequests[nodeID]...)
}

// The nodes a LAN entrance serves are recorded where they are: an entrance that
// dialed them anywhere else would reach nothing.
func TestLANNodesAreRecordedWhereTheyAre(t *testing.T) {
	harness := startLANEntrance(t)
	nodes := harness.service.State().Nodes
	if len(nodes) != 2 {
		t.Fatalf("the entrance serves %d nodes", len(nodes))
	}
	for index, node := range nodes {
		if node.ID != entrancetest.NodeIDs[index] || node.Name != entrancetest.NodeNames[index] || node.Address == "" {
			t.Fatalf("node %d is %+v", index, node)
		}
	}
	var listed bytes.Buffer
	if err := runLANNode([]string{"list", "--state", harness.service.root}, &listed); err != nil {
		t.Fatal(err)
	}
	var reported []map[string]string
	if err := json.Unmarshal(listed.Bytes(), &reported); err != nil || len(reported) != 2 {
		t.Fatalf("node list is %s (%v)", listed.String(), err)
	}
}

// openTestLANEntrance is an entrance of one test's own, with one node behind it:
// what an application's origin is allocated and recorded against.
func openTestLANEntrance(t *testing.T) (*lanService, string) {
	t.Helper()
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", "", 30); err != nil {
		t.Fatal(err)
	}
	node, err := nodecore.Initialize(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := addLANNode(root, "Desk", node.NodeID, node.ListenAddress, "", filepath.Join(t.TempDir(), "bootstrap")); err != nil {
		t.Fatal(err)
	}
	service, err := openLANService(root)
	if err != nil {
		t.Fatal(err)
	}
	return service, node.NodeID
}

// An application is served at an origin of its own, which is what keeps one
// application's browser storage out of another's, and which follows from the node
// and the application rather than from the order things were opened in: the same
// application is the same origin however often it is asked for, and it is recorded
// where a restart reads it.
func TestLANApplicationsGetOriginsOfTheirOwn(t *testing.T) {
	service, nodeID := openTestLANEntrance(t)
	first, err := service.Origin(nodeID, "editor")
	if err != nil {
		t.Fatal(err)
	}
	second, err := service.Origin(nodeID, "gallery")
	if err != nil || first == second {
		t.Fatalf("two applications are served at %q and %q (%v)", first, second, err)
	}
	if again, err := service.Origin(nodeID, "editor"); err != nil || again != first {
		t.Fatalf("an application moved: %q then %q (%v)", first, again, err)
	}
	for _, origin := range []string{first, second} {
		parsed, parseErr := url.Parse(origin)
		host, _, splitErr := net.SplitHostPort(parsed.Host)
		if parseErr != nil || splitErr != nil || parsed.Scheme != "https" || host != "127.0.0.1" {
			t.Fatalf("an application origin is %q", origin)
		}
	}
	// What the entrance recorded is what it serves: a mapping per application of a
	// node, each on a port of its own.
	state, err := loadLANState(service.root)
	if err != nil || len(state.Applications) != 2 {
		t.Fatalf("the entrance recorded %+v (%v)", state.Applications, err)
	}
	for _, application := range state.Applications {
		if application.NodeID != nodeID {
			t.Fatalf("an application of another node was recorded: %+v", application)
		}
	}
	// A node this entrance does not serve has no application this entrance serves.
	if _, err := service.Origin(strings.Repeat("99", 32), "editor"); err == nil {
		t.Fatal("an application was allocated for a node this entrance does not serve")
	}
}

// What a restart serves is what the state recorded: each application at the
// address it was given, and one whose port something else took left for the next
// open — at a new origin, because an origin that cannot be served is worse than
// one that changed before anybody used it.
func TestLANApplicationsAreServedAgainWhereTheRecordSays(t *testing.T) {
	service, nodeID := openTestLANEntrance(t)
	state, err := loadLANState(service.root)
	if err != nil {
		t.Fatal(err)
	}
	address, err := netaddr.Reserve(applicationHost)
	if err != nil {
		t.Fatal(err)
	}
	_, portText, _ := net.SplitHostPort(address)
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	// This is the file a run that served one application of that node leaves behind.
	state.Applications = []lanApplication{{NodeID: nodeID, AppID: "editor", Port: port}}
	if err := state.save(service.root); err != nil {
		t.Fatal(err)
	}
	restarted, err := openLANService(service.root)
	if err != nil {
		t.Fatal(err)
	}
	surfaces, err := restarted.Surfaces()
	if err != nil {
		t.Fatal(err)
	}
	if len(surfaces) != 2 || surfaces[1].Address != net.JoinHostPort(applicationHost, portText) {
		t.Fatalf("the restarted entrance serves %+v", surfaces)
	}
	if origin, err := restarted.Origin(nodeID, "editor"); err != nil || origin != "https://127.0.0.1:"+portText {
		t.Fatalf("a restarted entrance moved an application: %q (%v)", origin, err)
	}
	// An application whose address this entrance can no longer hold is dropped
	// rather than served at an address that is not there: it is opened again at a
	// new origin, and the state stops naming one. The listener a surface brings is
	// closed first, because that is what "this entrance was down" means: nothing of
	// it holds the address any more, and something else took it.
	if err := surfaces[1].Listener.Close(); err != nil {
		t.Fatal(err)
	}
	held, err := net.Listen("tcp4", net.JoinHostPort(applicationHost, portText))
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	again, err := openLANService(service.root)
	if err != nil {
		t.Fatal(err)
	}
	surfaces, err = again.Surfaces()
	if err != nil {
		t.Fatal(err)
	}
	if len(surfaces) != 1 || surfaces[0].Address != again.state.Listeners[0].Address {
		t.Fatalf("an entrance that cannot hold an application's port serves %+v", surfaces)
	}
	if dropped, err := loadLANState(service.root); err != nil || len(dropped.Applications) != 0 {
		t.Fatalf("the dropped origin is still recorded: %+v (%v)", dropped.Applications, err)
	}
	origin, err := again.Origin(nodeID, "editor")
	if err != nil || origin == "https://127.0.0.1:"+portText || !strings.HasPrefix(origin, "https://127.0.0.1:") {
		t.Fatalf("an application was not given a new origin: %q (%v)", origin, err)
	}
}

// Taking a node out of the entrance takes the origins of its applications with it:
// a mapping kept for a node this entrance does not serve describes less than the
// state did, and the entrance would not open on it.
func TestRemovingANodeTakesItsApplicationOrigins(t *testing.T) {
	service, nodeID := openTestLANEntrance(t)
	if _, err := service.Origin(nodeID, "editor"); err != nil {
		t.Fatal(err)
	}
	if _, err := removeLANNode(service.root, "Desk"); err != nil {
		t.Fatal(err)
	}
	state, err := loadLANState(service.root)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Nodes) != 0 || len(state.Applications) != 0 {
		t.Fatalf("removing a node left %+v and %+v", state.Nodes, state.Applications)
	}
}

// What this entrance records has to be something it can answer for: a mapping for a
// node it does not serve reaches nothing, and two applications on one port would
// answer for each other, so neither is a state it opens on.
func TestLANStateRefusesApplicationMappingsItCannotServe(t *testing.T) {
	service, nodeID := openTestLANEntrance(t)
	state, err := loadLANState(service.root)
	if err != nil {
		t.Fatal(err)
	}
	state.Applications = []lanApplication{{NodeID: strings.Repeat("99", 32), AppID: "editor", Port: 41234}}
	if err := state.save(service.root); err != nil {
		t.Fatal(err)
	}
	if _, err := loadLANState(service.root); err == nil {
		t.Fatal("a mapping for a node this entrance does not serve was accepted")
	}
	state.Applications = []lanApplication{
		{NodeID: nodeID, AppID: "editor", Port: 41234},
		{NodeID: nodeID, AppID: "gallery", Port: 41234},
	}
	if err := state.save(service.root); err != nil {
		t.Fatal(err)
	}
	if _, err := loadLANState(service.root); err == nil {
		t.Fatal("two applications sharing one port were accepted")
	}
	state.Applications = []lanApplication{
		{NodeID: nodeID, AppID: "editor", Port: 41234},
		{NodeID: nodeID, AppID: "editor", Port: 41235},
	}
	if err := state.save(service.root); err != nil {
		t.Fatal(err)
	}
	if _, err := loadLANState(service.root); err == nil {
		t.Fatal("two origins for one application were accepted")
	}
}

// An application listens where its entrance was told to serve it, while its origin
// stays the host this entrance recorded for its clients: an address an application
// is reached at is not the same thing as an address this machine listens on.
func TestLANApplicationsListenOnTheAddressTheyWereGiven(t *testing.T) {
	service, nodeID := openTestLANEntrance(t)
	address, err := netaddr.Reserve(applicationHost)
	if err != nil {
		t.Fatal(err)
	}
	_, portText, _ := net.SplitHostPort(address)
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	state, err := loadLANState(service.root)
	if err != nil {
		t.Fatal(err)
	}
	state.ApplicationsHost = "127.0.0.1"
	state.Applications = []lanApplication{{NodeID: nodeID, AppID: "editor", Port: port}}
	if err := state.save(service.root); err != nil {
		t.Fatal(err)
	}
	again, err := openLANService(service.root)
	if err != nil {
		t.Fatal(err)
	}
	// The surfaces are what a start binds, so they are asked for before anything is
	// opened here — the order an entrance itself runs in.
	surfaces, err := again.Surfaces()
	if err != nil {
		t.Fatal(err)
	}
	if len(surfaces) != 2 || surfaces[1].Address != net.JoinHostPort("127.0.0.1", portText) {
		t.Fatalf("an entrance told to serve its applications on loopback serves %+v", surfaces)
	}
	if surfaces[1].Listener == nil {
		t.Fatal("an application surface holds no listener of its own")
	}
	defer surfaces[1].Listener.Close()
	// What a client is sent to is the host this entrance is reached at, which is
	// what its certificate covers, and not the address the application listens on.
	origin, err := again.Origin(nodeID, "editor")
	if err != nil || origin != "https://127.0.0.1:"+portText {
		t.Fatalf("an application is reached at %q (%v)", origin, err)
	}
}
