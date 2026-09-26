package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/hxaxd/remote-everything/internal/backplane/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/gateway/devicecore"
	"github.com/hxaxd/remote-everything/internal/gateway/entrance"
	"github.com/hxaxd/remote-everything/internal/gateway/entrancetest"
	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
)

// A public entrance is a gateway shape, and the same behaviour suite drives it:
// what it does not do itself is terminate TLS or verify client certificates —
// the 443 entrance in front of it does, and stamps the fingerprint of the
// certificate it verified. The harness stands in for that entrance, which is the
// only thing this shape needs to be driven like any other.
func TestPublicEntranceBehaviour(t *testing.T) {
	entrancetest.Run(t, startPublicEntrance(t))
}

// What only a public entrance has: two surfaces, because the 443 entrance in
// front of it forwards pairing and everything else differently. Pairing is the
// one a client with no credential must reach.
func TestPublicEntranceAnswersPairingOnItsOwnSurface(t *testing.T) {
	harness := startPublicEntrance(t)
	if status, _, err := harness.Dial(nil, http.MethodPost, "/__remote_everything_pair", nil, nil); err != nil || status == http.StatusNotFound {
		t.Fatalf("the pairing surface answered a request meant for it with %d, %v", status, err)
	}
	if status, _, err := harness.Dial(nil, http.MethodGet, "/__remote_everything_pair", nil, nil); err != nil || status != http.StatusNotFound {
		t.Fatalf("the status surface answered for pairing: %d %v", status, err)
	}
}

// The host a request arrives on is what tells the three things apart that the
// entrance in front of this gateway forwards: the protocol, one application of one
// node, and the permission that entrance asks before it issues a certificate for
// one more application host. Everything else this gateway does not serve.
func TestPublicEntranceTellsRequestsApartByHost(t *testing.T) {
	harness := startPublicEntrance(t)
	nodes := harness.service.State().Nodes
	applicationHost := func(node gatewaycore.Node, appID string) string {
		t.Helper()
		host, err := gatewaycore.AppHost(node.ID, appID, harness.host)
		if err != nil {
			t.Fatal(err)
		}
		return host
	}
	// The entrance asks in its own name and without a credential of its own, on the
	// address it forwards to rather than on a host.
	ask := func(domain string) (int, string, error) {
		return harness.Dial(nil, http.MethodGet, "/__remote_everything_tls_ask?domain="+domain, nil, nil)
	}
	if status, body, err := ask(applicationHost(nodes[0], entrancetest.AppID)); err != nil || status != http.StatusOK {
		t.Fatalf("an application host was not allowed a certificate: %d %s %v", status, body, err)
	}
	// Every node this gateway serves has hostnames of its own, and one of them is
	// not the other.
	if status, body, err := ask(applicationHost(nodes[1], entrancetest.AppID)); err != nil || status != http.StatusOK {
		t.Fatalf("an application host of another node was not allowed a certificate: %d %s %v", status, body, err)
	}
	for _, refused := range []string{
		applicationHost(nodes[0], "missing"),                     // an application the node does not run
		"editor." + nodes[0].ID[:8] + ".other.example.com",       // another gateway's domain
		"editor." + strings.Repeat("99", 4) + "." + harness.host, // a node this gateway does not serve
		harness.host, // the gateway's own host
	} {
		if status, _, err := ask(refused); err != nil || status != http.StatusForbidden {
			t.Fatalf("%s was allowed a certificate: %d %v", refused, status, err)
		}
	}
	// A host that is none of the three is not answered as one of them, and neither
	// is an application host naming a node this gateway does not serve.
	for _, unknown := range []string{"elsewhere.example.com", "editor." + strings.Repeat("99", 4) + "." + harness.host} {
		response, body, err := harness.request(nil, harness.status, unknown, http.MethodGet, "/", nil, nil)
		if err != nil || response.StatusCode != http.StatusNotFound || !strings.Contains(string(body), `"not_found"`) {
			t.Fatalf("%s answered %d %s (%v)", unknown, response.StatusCode, body, err)
		}
	}
}

// publicHarness is the public entrance as the shared suite sees it: its two
// loopback surfaces, the host the entrance in front of it forwards requests for,
// the fingerprint it injects, and the two machines behind it.
type publicHarness struct {
	service      *publicService
	root         string
	host         string
	status       string
	pairing      string
	mutex        sync.Mutex
	nodeRequests map[string][]string
}

func startPublicEntrance(t *testing.T) *publicHarness {
	t.Helper()
	harness := &publicHarness{nodeRequests: map[string][]string{}}
	root := t.TempDir()
	harness.root = root
	if _, err := initializePublicState(root, "https://remote.example.com"); err != nil {
		t.Fatal(err)
	}
	// Each node is behind the tunnel this gateway owns: what its state recorded is
	// the loopback port its own tunnel server forwards from, and that is where a
	// request for that node arrives. A test answers on that same address, so the
	// entrance is opened and reached exactly as the deployment opens and reaches it.
	for index, id := range entrancetest.NodeIDs {
		added, err := addPublicNode(root, entrancetest.NodeNames[index], id, "", filepath.Join(t.TempDir(), "bootstrap"))
		if err != nil {
			t.Fatal(err)
		}
		harness.serveNode(t, id, added.NodeAddress)
	}
	service, err := openPublicService(root)
	if err != nil {
		t.Fatal(err)
	}
	surfaces, err := service.Surfaces()
	if err != nil {
		t.Fatal(err)
	}
	harness.service = service
	// The host the entrance in front of this gateway forwards is the host this
	// gateway recorded: every request the protocol has is asked on it, and an
	// application is reached on a host of its own under it.
	harness.host = hostOf(service.State().Origin)
	for index, surface := range surfaces {
		listener, listenErr := net.Listen("tcp", "127.0.0.1:0")
		if listenErr != nil {
			t.Fatal(listenErr)
		}
		go func(surface entrance.Surface) { _ = surface.Bind(listener) }(surface)
		t.Cleanup(func() { _ = listener.Close() })
		if index == 0 {
			harness.status = "http://" + listener.Addr().String()
		} else {
			harness.pairing = "http://" + listener.Addr().String()
		}
	}
	return harness
}

// serveNode answers for one machine behind the tunnel, on the address this
// gateway recorded for it, and records everything it was asked for.
func (harness *publicHarness) serveNode(t *testing.T, id, address string) {
	t.Helper()
	listener, err := net.Listen("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	node := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		harness.mutex.Lock()
		harness.nodeRequests[id] = append(harness.nodeRequests[id], request.URL.Path)
		harness.mutex.Unlock()
		if request.URL.Path == "/cookie-policy" {
			writer.Header().Add("Set-Cookie", "session=value; Domain=.example.com; Path=/; HttpOnly")
			writer.Header().Add("Set-Cookie", "__Host-remote_everything_web=forged; Path=/; Secure")
			writer.Header().Add("Set-Cookie", "remote_everything_web=forged; Path=/")
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
	})}
	go func() { _ = node.Serve(listener) }()
	t.Cleanup(func() { _ = node.Close() })
}

func (harness *publicHarness) Gateway() entrance.Gateway { return harness.service }

// Dial sends one request the way this shape's clients reach it: in the clear,
// through the entrance that authenticated them and said who they are. The
// entrance in front of this gateway forwards the host it was asked for, which for
// the protocol's own requests is the host this gateway recorded.
func (harness *publicHarness) Dial(credential *tls.Certificate, method, path string, header map[string]string, body []byte) (int, string, error) {
	// The entrance forwards the pairing endpoint to its own upstream and everything
	// else to this one, which is the whole of how it tells them apart.
	origin := harness.status
	if path == "/__remote_everything_pair" {
		origin = harness.pairing
	}
	response, contents, err := harness.request(credential, origin, harness.host, method, path, header, body)
	if err != nil {
		return 0, "", err
	}
	return response.StatusCode, string(contents), nil
}

// Open asks this gateway to open one application, which is a request on the host
// it recorded: what comes back is the application's own host, which the entrance in
// front of it resolves and which is what has to resolve here.
func (harness *publicHarness) Open(credential *tls.Certificate, node gatewaycore.Node, appID string) (int, string, error) {
	header := map[string]string{proxysecurity.NodeHeader: node.ID}
	response, _, err := harness.request(credential, harness.status, harness.host, http.MethodGet, "/__remote_everything/open/"+appID, header, nil)
	if err != nil {
		return 0, "", err
	}
	return response.StatusCode, response.Header.Get("Location"), nil
}

// DialApplication sends one request to one application's own host, which is the
// host this gateway serves that application under: the entrance in front of it
// issues a certificate for that host and forwards it here as it arrived.
func (harness *publicHarness) DialApplication(credential *tls.Certificate, node gatewaycore.Node, appID, method, path string, header map[string]string, body []byte) (int, string, error) {
	host, err := gatewaycore.AppHost(node.ID, appID, harness.host)
	if err != nil {
		return 0, "", err
	}
	response, contents, err := harness.request(credential, harness.status, host, method, path, header, body)
	if err != nil {
		return 0, "", err
	}
	return response.StatusCode, string(contents), nil
}

// request sends one request the way the entrance in front of this gateway forwards
// one: over plain HTTP to a loopback surface, in the name of the host that was
// asked for and with the fingerprint of the certificate the entrance verified.
func (harness *publicHarness) request(credential *tls.Certificate, origin, host, method, path string, header map[string]string, body []byte) (*http.Response, []byte, error) {
	request, err := http.NewRequest(method, origin+path, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	request.Host = host
	for name, value := range header {
		request.Header.Set(name, value)
	}
	// Whatever the client claimed is dropped, and the certificate the entrance
	// verified is what speaks for it.
	request.Header.Del("X-Remote-Everything-Client-Fingerprint")
	if credential != nil && len(credential.Certificate) > 0 {
		certificate, parseErr := x509.ParseCertificate(credential.Certificate[0])
		if parseErr != nil {
			return nil, nil, parseErr
		}
		request.Header.Set("X-Remote-Everything-Client-Fingerprint", devicecore.CertificateFingerprint(certificate))
	}
	// Opening an application is answered with the application's own host, and that
	// answer is what these requests are about: a client that followed it would be
	// testing the application rather than the redirect.
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	contents, _ := io.ReadAll(response.Body)
	return response, contents, nil
}

// A public invitation travels over a network nobody is watching, so the operator
// confirms the device after it pairs instead of admitting it on redemption.
func (harness *publicHarness) ApprovesInline() bool { return false }

func (harness *publicHarness) Approve(fingerprint string) error {
	var buffer bytes.Buffer
	return harness.service.trust.RunCLI([]string{"approve", fingerprint}, &buffer)
}

func (harness *publicHarness) NodeSaw(nodeID string) []string {
	harness.mutex.Lock()
	defer harness.mutex.Unlock()
	return append([]string{}, harness.nodeRequests[nodeID]...)
}

// Every node a public gateway serves is behind its own tunnel: its address is a
// loopback port this gateway's tunnel server forwards from, and the port in it is
// what that machine's tunnel agent has to publish.
func TestPublicNodesAreBehindTheirOwnTunnelPorts(t *testing.T) {
	harness := startPublicEntrance(t)
	nodes := harness.service.State().Nodes
	if len(nodes) != 2 {
		t.Fatalf("the gateway serves %d nodes", len(nodes))
	}
	seen := map[string]bool{}
	for index, node := range nodes {
		if node.ID != entrancetest.NodeIDs[index] || node.Name != entrancetest.NodeNames[index] {
			t.Fatalf("node %d is %+v", index, node)
		}
		if !strings.HasPrefix(node.Address, "127.0.0.1:") || seen[node.Address] {
			t.Fatalf("node %d is at %q", index, node.Address)
		}
		seen[node.Address] = true
	}
	// Adding a node this gateway already serves keeps the port its tunnel agent
	// publishes: moving it would take that machine out of reach.
	again, err := addPublicNode(harness.root, entrancetest.NodeNames[0], entrancetest.NodeIDs[0], "", filepath.Join(t.TempDir(), "bootstrap"))
	if err != nil {
		t.Fatal(err)
	}
	if again.NodeAddress != nodes[0].Address || !again.RestartRequired {
		t.Fatalf("re-adding a node moved it: %+v", again)
	}
	// And a node is added to a gateway that serves nothing yet, which is where one
	// is added in the first place.
	if _, err := addPublicNode(harness.root, entrancetest.NodeNames[1], entrancetest.NodeIDs[1], "", filepath.Join(t.TempDir(), "bootstrap")); err != nil {
		t.Fatal(err)
	}
	var listed bytes.Buffer
	if err := runPublicNode([]string{"list", "--state", harness.root}, &listed); err != nil {
		t.Fatal(err)
	}
	var reported []map[string]string
	if err := json.Unmarshal(listed.Bytes(), &reported); err != nil || len(reported) != 2 {
		t.Fatalf("node list is %s (%v)", listed.String(), err)
	}
}
