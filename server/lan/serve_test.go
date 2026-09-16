package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/entrancetest"
)

// A LAN entrance is a gateway shape, so its behaviour is the shared one: what it
// adds here is only how its clients reach it, which is over the TLS it terminates
// itself with the certificate they pinned.
func TestLANEntranceBehaviour(t *testing.T) {
	entrancetest.Run(t, startLANEntrance(t))
}

// lanHarness is the LAN entrance as the shared suite sees it.
type lanHarness struct {
	service      *lanService
	origin       string
	pinned       *x509.Certificate
	nodeRequests []string
}

func startLANEntrance(t *testing.T) *lanHarness {
	t.Helper()
	harness := &lanHarness{}
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		harness.nodeRequests = append(harness.nodeRequests, request.URL.Path)
		writer.Header().Set("Content-Type", "application/json")
		if request.URL.Path != "/__local_remote_control" {
			_, _ = io.WriteString(writer, `{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}`)
			return
		}
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
	}))
	t.Cleanup(node.Close)

	root := t.TempDir()
	if _, err := initializeLAN(root, strings.TrimPrefix(node.URL, "http://"), "127.0.0.1", 30, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	service, err := openLANService(root)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := loadLANCertificate(root, service.state)
	if err != nil {
		t.Fatal(err)
	}
	servers, err := service.Servers()
	if err != nil {
		t.Fatal(err)
	}
	// A deployment binds the address its state recorded; a test binds one of its
	// own so two entrances never collide, and serves the same surface on it.
	server := servers[0]
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = server.ServeTLS(listener, "", "") }()
	t.Cleanup(func() { _ = server.Close() })

	harness.service = service
	harness.origin = "https://" + listener.Addr().String()
	harness.pinned = certificate
	return harness
}

func (harness *lanHarness) Gateway() entrance.Gateway { return harness.service }

func (harness *lanHarness) Dial(credential *tls.Certificate, method, path string, header map[string]string, body []byte) (int, string, error) {
	configuration := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: x509.NewCertPool()}
	configuration.RootCAs.AddCert(harness.pinned)
	if credential != nil {
		configuration.Certificates = []tls.Certificate{*credential}
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: configuration}}
	request, err := http.NewRequest(method, harness.origin+path, bytes.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	for name, value := range header {
		request.Header.Set(name, value)
	}
	response, err := client.Do(request)
	if err != nil {
		return 0, "", err
	}
	defer response.Body.Close()
	contents, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(contents), nil
}

// A LAN invitation is handed over in person, so redeeming it is the whole
// admission and there is no operator step for this shape.
func (harness *lanHarness) ApprovesInline() bool { return true }

func (harness *lanHarness) Approve(string) error { return nil }

func (harness *lanHarness) NodeSaw() []string { return harness.nodeRequests }
