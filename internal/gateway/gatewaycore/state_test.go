package gatewaycore

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/infra/netaddr"
)

var (
	testInstallation = strings.Repeat("a1", 32)
	testNode         = Node{ID: strings.Repeat("b2", 32), Name: "Desk", Address: "127.0.0.1:58628"}
	testOtherNode    = Node{ID: strings.Repeat("c3", 32), Name: "Laptop", Address: "127.0.0.1:58632"}
)

func testListeners(t *testing.T) []Listener {
	t.Helper()
	listeners, err := AllocateListeners(testPreferences())
	if err != nil {
		t.Fatal(err)
	}
	return listeners
}

func testPreferences() []ListenerPreference {
	return []ListenerPreference{
		{Name: "status", Host: "127.0.0.1", PreferredPort: 58629},
		{Name: "pairing", Host: "127.0.0.1", PreferredPort: 58631},
		{Name: "frps", Host: "127.0.0.1", PreferredPort: 58630},
	}
}

// Every gateway records the same thing about itself: the identity a node binds
// it by, the origin its clients dial, the listeners it serves, and the nodes it
// serves them for.
func TestStateRoundTripKeepsIdentityListenersAndNodes(t *testing.T) {
	state, err := NewState(testInstallation, "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, node := range []Node{testNode, testOtherNode} {
		if state, err = state.AddNode(node); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(t.TempDir(), "gateway.json")
	if err := state.Save(path); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.InstallationID != testInstallation || loaded.Origin != "https://gateway.example" || len(loaded.Listeners) != len(state.Listeners) {
		t.Fatalf("round trip changed the state: %+v", loaded)
	}
	for _, preference := range testPreferences() {
		address, err := loaded.Address(preference.Name)
		if err != nil || !netaddr.ValidListen(address) {
			t.Fatalf("listener %s = %q, %v", preference.Name, address, err)
		}
	}
	if _, err := loaded.Address("missing"); err == nil {
		t.Fatal("an unknown listener name was answered")
	}
	if len(loaded.Nodes) != 2 || loaded.Nodes[0] != testNode || loaded.Nodes[1] != testOtherNode {
		t.Fatalf("round trip changed the nodes: %+v", loaded.Nodes)
	}
	if node, ok := loaded.FindNode(testOtherNode.ID); !ok || node != testOtherNode {
		t.Fatalf("a node this gateway serves was not found: %+v %v", node, ok)
	}
	if _, ok := loaded.FindNode(strings.Repeat("ee", 32)); ok {
		t.Fatal("a node this gateway does not serve was found")
	}
}

// A gateway records itself before it has a node and needs the state it was given
// to be valid at that point: an operator adds nodes to a gateway that exists.
func TestANewStateServesNoNodeYet(t *testing.T) {
	state, err := NewState(testInstallation, "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	if state.Nodes == nil || len(state.Nodes) != 0 {
		t.Fatalf("a new gateway recorded nodes: %+v", state.Nodes)
	}
	path := filepath.Join(t.TempDir(), "gateway.json")
	if err := state.Save(path); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadState(path); err != nil {
		t.Fatal(err)
	}
}

func TestAddNodeRecordsAndUpdatesOneNode(t *testing.T) {
	state, err := NewState(testInstallation, "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	if state, err = state.AddNode(testNode); err != nil {
		t.Fatal(err)
	}
	if state, err = state.AddNode(testOtherNode); err != nil {
		t.Fatal(err)
	}
	// A node that moved or was renamed is the same node: it is brought up to date
	// where it is, rather than recorded twice.
	moved := Node{ID: testNode.ID, Name: "Studio", Address: "127.0.0.1:58640"}
	updated, err := state.AddNode(moved)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Nodes) != 2 || updated.Nodes[0] != moved || updated.Nodes[1] != testOtherNode {
		t.Fatalf("updating a node changed the list: %+v", updated.Nodes)
	}
	// A name belongs to one node: it is how an operator and a client say which
	// machine they mean.
	if _, err := updated.AddNode(Node{ID: strings.Repeat("d4", 32), Name: "Studio", Address: "127.0.0.1:58641"}); err == nil {
		t.Fatal("two nodes were given the same name")
	}
}

func TestLoadStateRejectsStatesNothingCanServe(t *testing.T) {
	id := `"installation_id":"` + testInstallation + `"`
	origin := `"origin":"https://gateway.example"`
	listeners := `"listeners":[{"name":"lan","address":"0.0.0.0:58626"}]`
	validNode := `{"id":"` + testNode.ID + `","name":"Desk","address":"192.168.1.5:58627"}`
	node := func(value string) string { return `"nodes":[` + value + `]` }
	for name, contents := range map[string]string{
		"unknown field":     `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(validNode) + `,"extra":true}`,
		"no listeners":      `{"schema":1,` + id + `,` + origin + `,"listeners":[],` + node(validNode) + `}`,
		"duplicate name":    `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"},{"name":"lan","address":"0.0.0.0:58627"}],` + node(validNode) + `}`,
		"duplicate address": `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"},{"name":"lan2","address":"0.0.0.0:58626"}],` + node(validNode) + `}`,
		"hostname":          `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"node.example:58626"}],` + node(validNode) + `}`,
		"privileged port":   `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:80"}],` + node(validNode) + `}`,
		"other schema":      `{"schema":2,` + id + `,` + origin + `,` + listeners + `,` + node(validNode) + `}`,
		// The origin is what clients dial, so it is part of what a gateway is.
		"no origin":    `{"schema":1,` + id + `,` + listeners + `,` + node(validNode) + `}`,
		"plain origin": `{"schema":1,` + id + `,"origin":"http://gateway.example",` + listeners + `,` + node(validNode) + `}`,
		"origin path":  `{"schema":1,` + id + `,"origin":"https://gateway.example/apps",` + listeners + `,` + node(validNode) + `}`,
		"origin query": `{"schema":1,` + id + `,"origin":"https://gateway.example?next=evil",` + listeners + `,` + node(validNode) + `}`,
		"origin user":  `{"schema":1,` + id + `,"origin":"https://user@gateway.example",` + listeners + `,` + node(validNode) + `}`,
		// A node is the machine behind this gateway, and a request names it by its
		// id: one that is not an id, one with no name, or two of the same cannot be
		// told apart or reached.
		"no nodes field":   `{"schema":1,` + id + `,` + origin + `,` + listeners + `}`,
		"short node id":    `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(`{"id":"b2b2","name":"Desk","address":"192.168.1.5:58627"}`) + `}`,
		"no node name":     `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(`{"id":"`+testNode.ID+`","name":"","address":"192.168.1.5:58627"}`) + `}`,
		"blank node name":  `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(`{"id":"`+testNode.ID+`","name":" Desk","address":"192.168.1.5:58627"}`) + `}`,
		"duplicate node":   `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(validNode+`,`+`{"id":"`+testNode.ID+`","name":"Other","address":"192.168.1.6:58627"}`) + `}`,
		"same node name":   `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(validNode+`,`+`{"id":"`+testOtherNode.ID+`","name":"Desk","address":"192.168.1.6:58627"}`) + `}`,
		"same address":     `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(validNode+`,`+`{"id":"`+testOtherNode.ID+`","name":"Laptop","address":"192.168.1.5:58627"}`) + `}`,
		"listener address": `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(`{"id":"`+testNode.ID+`","name":"Desk","address":"0.0.0.0:58626"}`) + `}`,
		"node no address":  `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(`{"id":"`+testNode.ID+`","name":"Desk","address":""}`) + `}`,
		"node wildcard":    `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(`{"id":"`+testNode.ID+`","name":"Desk","address":"0.0.0.0:58628"}`) + `}`,
	} {
		path := filepath.Join(t.TempDir(), "gateway.json")
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadState(path); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	valid := `{"schema":1,` + id + `,` + origin + `,` + listeners + `,` + node(validNode) + `}`
	path := filepath.Join(t.TempDir(), "gateway.json")
	if err := os.WriteFile(path, []byte(valid), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadState(path); err != nil {
		t.Fatalf("a wildcard listener with a node on the network was rejected: %v", err)
	}
}

func TestNewStateRefusesAGatewayThatServesNothing(t *testing.T) {
	if _, err := NewState(testInstallation, "https://gateway.example", nil); err == nil {
		t.Fatal("a gateway with no listeners was recorded")
	}
}

// A node address is reserved the way a listener's is, and stays clear of every
// address this gateway already uses: two entries sharing one would answer for
// each other.
func TestAllocateNodeAddressStaysClearOfEveryAddressInUse(t *testing.T) {
	state, err := NewState(testInstallation, "https://gateway.example", []Listener{{Name: "status", Address: "127.0.0.1:58629"}})
	if err != nil {
		t.Fatal(err)
	}
	first, err := state.AllocateNodeAddress("127.0.0.1", 58629)
	if err != nil {
		t.Fatal(err)
	}
	if first == "127.0.0.1:58629" {
		t.Fatalf("a listener's address was handed out again: %q", first)
	}
	if state, err = state.AddNode(Node{ID: testNode.ID, Name: "Desk", Address: first}); err != nil {
		t.Fatal(err)
	}
	second, err := state.AllocateNodeAddress("127.0.0.1", 58629)
	if err != nil {
		t.Fatal(err)
	}
	if second == first || second == "127.0.0.1:58629" {
		t.Fatalf("an address already in use was handed out again: %q", second)
	}
	if !netaddr.ValidLoopback(second) {
		t.Fatalf("a node address was allocated off loopback: %q", second)
	}
}

// Repair moves the ports and nothing else: a listener's name and host, and each
// node's id and name, are what the rest of the deployment was pointed at.
func TestRepairKeepsNamesHostsAndNodes(t *testing.T) {
	state, err := NewState(testInstallation, "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	if state, err = state.AddNode(testNode); err != nil {
		t.Fatal(err)
	}
	repaired, err := state.Repair(map[string]int{"status": 58629, "pairing": 58631, "frps": 58630})
	if err != nil {
		t.Fatal(err)
	}
	if repaired.InstallationID != state.InstallationID || repaired.Schema != state.Schema || repaired.Origin != state.Origin {
		t.Fatalf("repair changed the identity: %+v", repaired)
	}
	before := map[string]string{}
	for _, listener := range state.Listeners {
		before[listener.Name] = listener.Address
	}
	for _, listener := range repaired.Listeners {
		host, _, err := net.SplitHostPort(listener.Address)
		if err != nil || host != netaddrHost(before[listener.Name]) || !netaddr.ValidListen(listener.Address) {
			t.Fatalf("repair changed host or validity of %s: %q", listener.Name, listener.Address)
		}
	}
	// Where a node is belongs to whoever added it: repairing the gateway's own
	// ports leaves a node on the network where it is.
	if len(repaired.Nodes) != 1 || repaired.Nodes[0] != testNode {
		t.Fatalf("repairing listeners moved a node: %+v", repaired.Nodes)
	}
}

// RepairNodePorts is for a gateway that owns its node addresses — a tunnel port
// it holds itself — and moves them while keeping every node's identity.
func TestRepairNodePortsKeepsEveryNodeIdentity(t *testing.T) {
	state, err := NewState(testInstallation, "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	for _, node := range []Node{testNode, testOtherNode} {
		if state, err = state.AddNode(node); err != nil {
			t.Fatal(err)
		}
	}
	repaired, err := state.RepairNodePorts(58628)
	if err != nil {
		t.Fatal(err)
	}
	if len(repaired.Nodes) != 2 {
		t.Fatalf("repairing node ports changed how many there are: %+v", repaired.Nodes)
	}
	seen := map[string]bool{}
	for index, node := range repaired.Nodes {
		original := state.Nodes[index]
		if node.ID != original.ID || node.Name != original.Name || !netaddr.ValidLoopback(node.Address) {
			t.Fatalf("node %d is %+v", index, node)
		}
		if seen[node.Address] {
			t.Fatalf("two nodes were given one address: %q", node.Address)
		}
		seen[node.Address] = true
		if address, err := repaired.Address("status"); err == nil && address == node.Address {
			t.Fatalf("a node was given a listener's address: %q", node.Address)
		}
	}
}

func netaddrHost(address string) string {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return ""
	}
	return host
}
