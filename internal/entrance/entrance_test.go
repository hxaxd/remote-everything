package entrance

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

const (
	testInstallationID = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	testOrigin         = "https://remote.example.com"
)

// stubNodes is the one machine the stub gateway serves: a request names it by its
// id, and an invitation says which one it opens.
var stubNodes = []gatewaycore.Node{{ID: strings.Repeat("11", 32), Name: "Desk", Address: "127.0.0.1:58628"}}

// stubGateway is a gateway shape the driver can be handed in place of either
// real one: the state it recorded, the trust it admits devices with, and the
// surfaces it says it serves are all the driver asks a shape for.
type stubGateway struct {
	state       gatewaycore.State
	trust       *devicecore.Trust
	surfaces    []Surface
	surfacesErr error
}

func (gateway stubGateway) State() gatewaycore.State { return gateway.state }
func (gateway stubGateway) Trust() *devicecore.Trust { return gateway.trust }
func (gateway stubGateway) Surfaces() ([]Surface, error) {
	return gateway.surfaces, gateway.surfacesErr
}

// stubNode is the surface device trust protects. Nothing here asks it much;
// opening a trust needs it to exist and to say what it serves, which is all it
// does.
type stubNode struct{}

func (stubNode) ServeNode(string, http.ResponseWriter, *http.Request) {}

func (stubNode) ServeApplication(string, string, http.ResponseWriter, *http.Request) {}

func (stubNode) ConnectedList(nodeID string) (json.RawMessage, bool) {
	if _, ok := stubNodeFor(nodeID); !ok {
		return nil, false
	}
	return json.RawMessage(`{"ok":true,"computer_connected":true,"code":"ready","apps":[]}`), true
}

func (stubNode) Nodes() []gatewaycore.Node { return stubNodes }

func stubNodeFor(nodeID string) (gatewaycore.Node, bool) {
	return gatewaycore.FindNode(stubNodes, nodeID)
}

func openStubGateway(t *testing.T, root, address string) stubGateway {
	t.Helper()
	trust, err := devicecore.Open(devicecore.Config{Root: root, InstallationID: testInstallationID, Origin: testOrigin, Node: stubNode{}})
	if err != nil {
		t.Fatal(err)
	}
	state, err := gatewaycore.NewState(testInstallationID, testOrigin, []gatewaycore.Listener{{Name: "status", Address: address}})
	if err != nil {
		t.Fatal(err)
	}
	for _, node := range stubNodes {
		if state, err = state.AddNode(node); err != nil {
			t.Fatal(err)
		}
	}
	return stubGateway{state: state, trust: trust}
}

// freeAddress is an address nothing is listening on, so the driver can bind it
// itself the way it binds the one a deployment recorded.
func freeAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return address
}

func discardLog(string, string, string, ...string) {}

// Where a gateway says it serves is where the driver binds it, and answering
// there is the shape's: the driver hands over a bound listener rather than
// serving anything on it.
func TestServeBindsTheAddressTheGatewayRecorded(t *testing.T) {
	address := freeAddress(t)
	gateway := openStubGateway(t, t.TempDir(), address)
	bound := ""
	gateway.surfaces = []Surface{{
		Address: address,
		Bind: func(listener net.Listener) error {
			bound = listener.Addr().String()
			return nil
		},
	}}
	var reported []string
	if err := Serve(gateway, func(component, level, message string, keyValues ...string) {
		reported = append(reported, component, level, message, strings.Join(keyValues, "="))
	}); err != nil {
		t.Fatalf("serving stopped with %v", err)
	}
	if bound != address {
		t.Fatalf("the shape was handed %q instead of the recorded address %q", bound, address)
	}
	if strings.Join(reported, " ") != "gateway info listening path="+address {
		t.Fatalf("what was being served was not reported: %v", reported)
	}
}

// Every surface a gateway declares is served at once, and the server is what
// stops when one of them stops — not one surface at a time.
func TestServeServesEverySurfaceUntilOneStops(t *testing.T) {
	stopped := errors.New("the entrance closed")
	var bound [2]bool
	secondBound := make(chan struct{})
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })

	gateway := openStubGateway(t, t.TempDir(), freeAddress(t))
	gateway.surfaces = []Surface{
		{Address: freeAddress(t), Bind: func(net.Listener) error {
			bound[0] = true
			<-secondBound
			return stopped
		}},
		{Address: freeAddress(t), Bind: func(net.Listener) error {
			bound[1] = true
			close(secondBound)
			<-release
			return nil
		}},
	}
	if err := Serve(gateway, discardLog); err != stopped {
		t.Fatalf("serving stopped with %v instead of what a surface stopped with", err)
	}
	if !bound[0] || !bound[1] {
		t.Fatalf("not every surface the gateway declared was served: %v", bound)
	}
}

func TestServeRefusesAGatewayThatServesNothing(t *testing.T) {
	gateway := openStubGateway(t, t.TempDir(), freeAddress(t))
	if err := Serve(gateway, discardLog); err == nil {
		t.Fatal("a gateway that serves nothing was served")
	}
}

// A shape says what it serves out of what it opened, so a shape that cannot
// load its material has nothing to serve: the driver stops before answering
// anything rather than half-serving what it was told.
func TestServeStopsWhenAShapeCannotSayWhatItServes(t *testing.T) {
	served := false
	gateway := openStubGateway(t, t.TempDir(), freeAddress(t))
	gateway.surfacesErr = errors.New("invalid entrance state")
	gateway.surfaces = []Surface{{Address: freeAddress(t), Bind: func(net.Listener) error {
		served = true
		return nil
	}}}
	err := Serve(gateway, discardLog)
	if err == nil || served {
		t.Fatalf("serving a gateway that cannot be opened answered %v, served=%v", err, served)
	}
}

// An address the deployment already has something on is a gateway that cannot
// start, and it fails there rather than serving somewhere else.
func TestServeStopsWhenAnAddressIsAlreadyTaken(t *testing.T) {
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	served := false
	gateway := openStubGateway(t, t.TempDir(), taken.Addr().String())
	gateway.surfaces = []Surface{{Address: taken.Addr().String(), Bind: func(net.Listener) error {
		served = true
		return nil
	}}}
	if err := Serve(gateway, discardLog); err == nil || served {
		t.Fatalf("serving an address that is taken answered %v, served=%v", err, served)
	}
}

// A command line offers more than the two commands every gateway has, and what
// to say about the rest is a shape's: the driver reports that it did not serve
// the command, without opening anything or choosing an exit code for the shape.
func TestRunLeavesWhatItDoesNotServeToTheShape(t *testing.T) {
	for _, args := range [][]string{
		nil,
		{"repair"},
		{"serve", "--bogus"},
		{"serve", "extra"},
		{"device", "--unknown"},
	} {
		opened := false
		open := func(string) (Gateway, error) {
			opened = true
			return nil, errors.New("unused")
		}
		handled, code := Run(args, open, io.Discard, io.Discard)
		if handled || code != 0 {
			t.Fatalf("%v was handled as %v with code %d", args, handled, code)
		}
		if opened {
			t.Fatalf("%v opened a gateway for a command that is not served", args)
		}
	}
}

// A gateway that stopped serving is a gateway that failed, so the operator sees
// the reason and an exit code that says so.
func TestRunReportsAStoppedServerAsAFailure(t *testing.T) {
	address := freeAddress(t)
	var stderr bytes.Buffer
	handled, code := Run([]string{"serve", "--state", t.TempDir()}, func(string) (Gateway, error) {
		gateway := openStubGateway(t, t.TempDir(), address)
		gateway.surfaces = []Surface{{Address: address, Bind: func(net.Listener) error {
			return errors.New("the tunnel closed")
		}}}
		return gateway, nil
	}, io.Discard, &stderr)
	if !handled || code != 1 {
		t.Fatalf("a stopped server was handled as %v with code %d", handled, code)
	}
}

func TestRunReportsAGatewayThatCannotBeOpened(t *testing.T) {
	open := func(string) (Gateway, error) { return nil, errors.New("invalid gateway state") }
	for _, args := range [][]string{{"serve", "--state", "missing"}, {"device", "--state", "missing", "list"}} {
		var stderr bytes.Buffer
		handled, code := Run(args, open, io.Discard, &stderr)
		if !handled || code != 1 || !strings.Contains(stderr.String(), "invalid gateway state") {
			t.Fatalf("%v answered %v with code %d and %q", args, handled, code, stderr.String())
		}
	}
}

// The device CLI is the same for every shape, so the driver runs it on the
// gateway it opened: the invitations it hands out describe that gateway, not
// whichever shape happens to be running.
func TestRunRunsTheDeviceCLIOfTheGatewayItOpened(t *testing.T) {
	root := t.TempDir()
	open := func(string) (Gateway, error) { return openStubGateway(t, root, freeAddress(t)), nil }

	var stdout, stderr bytes.Buffer
	handled, code := Run([]string{"device", "--state", root, "invite", "--name", "Test Phone", "--node", "Desk", "--ttl", "10m"}, open, &stdout, &stderr)
	if !handled || code != 0 {
		t.Fatalf("an invitation was not issued: %v code %d %s", handled, code, stderr.String())
	}
	var issued struct {
		SetupURI string `json:"setup_uri"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &issued); err != nil {
		t.Fatalf("invitation output %q: %v", stdout.String(), err)
	}
	uri, err := url.Parse(issued.SetupURI)
	if err != nil {
		t.Fatalf("setup URI %q: %v", issued.SetupURI, err)
	}
	carried := uri.Query()
	if uri.Scheme != "remote-everything" || uri.Host != "setup" ||
		carried.Get("node") != stubNodes[0].ID || carried.Get("node_name") != stubNodes[0].Name || carried.Get("origin") != testOrigin {
		t.Fatalf("the invitation does not describe the node it was issued for: %s", issued.SetupURI)
	}

	stdout.Reset()
	stderr.Reset()
	handled, code = Run([]string{"device", "--state", root, "destroy"}, open, &stdout, &stderr)
	if !handled || code != 1 || !strings.Contains(stderr.String(), "unknown device action") {
		t.Fatalf("an unknown device action answered %v with code %d and %q", handled, code, stderr.String())
	}
}
