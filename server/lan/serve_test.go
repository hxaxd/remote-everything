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
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/entrancetest"
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

func startLANEntrance(t *testing.T) *lanHarness {
	t.Helper()
	harness := &lanHarness{nodeRequests: map[string][]string{}}
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", 30); err != nil {
		t.Fatal(err)
	}
	// Each node is a machine of its own, at the address this entrance records for
	// it: that address is what the entrance dials, and what a request for that node
	// arrives at.
	for index, id := range entrancetest.NodeIDs {
		address := harness.startNode(t, id)
		bundle := filepath.Join(t.TempDir(), "bootstrap")
		if _, err := addLANNode(root, entrancetest.NodeNames[index], id, address, bundle); err != nil {
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
	// A deployment binds the address its state recorded; a test binds one of its
	// own so two entrances never collide, and serves the same surface on it.
	surface := surfaces[0]
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = surface.Bind(listener) }()
	t.Cleanup(func() { _ = listener.Close() })

	harness.service = service
	harness.origin = "https://" + listener.Addr().String()
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
