package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"testing"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/entrancetest"
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

// publicHarness is the public entrance as the shared suite sees it: its two
// loopback surfaces, and the fingerprint the entrance in front of it injects.
type publicHarness struct {
	service      *publicService
	status       string
	pairing      string
	nodeRequests []string
}

func startPublicEntrance(t *testing.T) *publicHarness {
	t.Helper()
	harness := &publicHarness{}
	root := t.TempDir()
	if _, err := initializePublicState(root, t.TempDir(), "https://remote.example.com"); err != nil {
		t.Fatal(err)
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	state, err := paths.loadState()
	if err != nil {
		t.Fatal(err)
	}
	// A deployment finds its node at the tunnel listener the tunnel brings its
	// control channel in on; a test answers on that same address, so the entrance
	// is opened and reached exactly as the deployment opens and reaches it.
	nodeAddress, err := state.Address("node_tunnel")
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", nodeAddress)
	if err != nil {
		t.Fatal(err)
	}
	node := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		harness.nodeRequests = append(harness.nodeRequests, request.URL.Path)
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
	})}
	go func() { _ = node.Serve(listener) }()
	t.Cleanup(func() { _ = node.Close() })

	service, err := openPublicService(root)
	if err != nil {
		t.Fatal(err)
	}
	servers, err := service.Servers()
	if err != nil {
		t.Fatal(err)
	}
	harness.service = service
	for index, server := range servers {
		listener, listenErr := net.Listen("tcp", "127.0.0.1:0")
		if listenErr != nil {
			t.Fatal(listenErr)
		}
		go func(server *http.Server) { _ = server.Serve(listener) }(server)
		t.Cleanup(func() { _ = server.Close() })
		if index == 0 {
			harness.status = "http://" + listener.Addr().String()
		} else {
			harness.pairing = "http://" + listener.Addr().String()
		}
	}
	return harness
}

func (harness *publicHarness) Gateway() entrance.Gateway { return harness.service }

// Dial sends one request the way this shape's clients reach it: in the clear,
// through the entrance that authenticated them and said who they are.
func (harness *publicHarness) Dial(credential *tls.Certificate, method, path string, header map[string]string, body []byte) (int, string, error) {
	origin := harness.status
	if path == "/__remote_everything_pair" {
		origin = harness.pairing
	}
	request, err := http.NewRequest(method, origin+path, bytes.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	for name, value := range header {
		request.Header.Set(name, value)
	}
	// Whatever the client claimed is dropped, and the certificate the entrance
	// verified is what speaks for it.
	request.Header.Del("X-Remote-Everything-Client-Fingerprint")
	if credential != nil && len(credential.Certificate) > 0 {
		certificate, parseErr := x509.ParseCertificate(credential.Certificate[0])
		if parseErr != nil {
			return 0, "", parseErr
		}
		request.Header.Set("X-Remote-Everything-Client-Fingerprint", devicecore.CertificateFingerprint(certificate))
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0, "", err
	}
	defer response.Body.Close()
	contents, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(contents), nil
}

// A public invitation travels over a network nobody is watching, so the operator
// confirms the device after it pairs instead of admitting it on redemption.
func (harness *publicHarness) ApprovesInline() bool { return false }

func (harness *publicHarness) Approve(fingerprint string) error {
	var buffer bytes.Buffer
	return harness.service.trust.RunCLI([]string{"approve", fingerprint}, &buffer)
}

func (harness *publicHarness) NodeSaw() []string { return harness.nodeRequests }
