package main

import (
	"bytes"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/nodecore"
)

func entryNames(t *testing.T, directory string) []string {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	return names
}

// A LAN entrance is a service of its own: it keeps its state in its own root and
// never reads a node's, and the nodes it serves are separate services that may
// well be separate machines. They meet only through the identity bundle an
// operator carries over.
func TestInitializeLAN(t *testing.T) {
	// The operator names the state directory here for the first time, so it is one
	// that does not exist yet: init creates it the way the other shapes do.
	root := filepath.Join(t.TempDir(), "lan-state")
	first, err := initializeLAN(root, "127.0.0.1", 30)
	if err != nil {
		t.Fatal(err)
	}
	origin, parseErr := url.Parse(first.Origin)
	if !first.OK || parseErr != nil || origin.Scheme != "https" || origin.Hostname() != "127.0.0.1" || origin.Port() == "" || len(first.CertificateFingerprint) != 64 || len(first.InstallationID) != 64 {
		t.Fatalf("unexpected init result: %+v", first)
	}
	initial, err := loadLANState(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(initial.Nodes) != 0 {
		t.Fatalf("init recorded nodes: %+v", initial.Nodes)
	}
	if initial.InstallationID != first.InstallationID {
		t.Fatalf("entrance state lost its identity: %+v", initial)
	}
	if address, err := initial.Address("lan"); err != nil || address != first.ListenAddress {
		t.Fatalf("entrance state does not carry its listener by name: %q %v", address, err)
	}
	want := []string{"lan.json", initial.LAN.CertificateFile, initial.LAN.PrivateKeyFile}
	sort.Strings(want)
	if entries := entryNames(t, root); !sameNames(entries, want) {
		t.Fatalf("entrance root holds %v, want %v", entries, want)
	}
	// There is nothing to reach until a node is added, and nothing to serve.
	if _, err := openLANService(root); err == nil {
		t.Fatal("an entrance serving no node was opened")
	}
	second, err := initializeLAN(root, "127.0.0.1", 30)
	if err != nil || second.CertificateFingerprint != first.CertificateFingerprint {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
	if _, err := initializeLAN(root, "localhost", 30); err == nil {
		t.Fatal("accepted an existing certificate for a different host")
	}
	if _, err := initializeLAN(root, "::1", 30); err == nil {
		t.Fatal("accepted an IPv6 host while the LAN service is IPv4-only")
	}
}

// Adding a node records where this entrance reaches that machine and hands it the
// identity bundle it binds this entrance with. The node is wherever the operator
// says it is, which is that machine's own address on the network.
func TestAddLANNodeRecordsAndDeliversOneNode(t *testing.T) {
	nodeRoot := t.TempDir()
	node, err := nodecore.Initialize(nodeRoot, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", 30); err != nil {
		t.Fatal(err)
	}
	bootstrapDir := filepath.Join(t.TempDir(), "bootstrap")
	added, err := addLANNode(root, "Desk", node.NodeID, node.ListenAddress, bootstrapDir)
	if err != nil {
		t.Fatal(err)
	}
	if !added.OK || added.NodeID != node.NodeID || added.NodeName != "Desk" || added.NodeAddress != node.ListenAddress || added.NodeBootstrap != filepath.Clean(bootstrapDir) || !added.RestartRequired {
		t.Fatalf("unexpected node result: %+v", added)
	}
	state, err := loadLANState(root)
	if err != nil || len(state.Nodes) != 1 || state.Nodes[0].ID != node.NodeID || state.Nodes[0].Address != node.ListenAddress {
		t.Fatalf("the entrance did not record where its node is: %+v %v", state.Nodes, err)
	}
	// The node knows nothing about the entrance until it imports the bundle, and
	// what it then holds is the token this entrance minted for that node.
	if state, err := nodecore.LoadState(nodeRoot); err != nil || len(state.Bindings) != 0 {
		t.Fatalf("the entrance reached into the node state: %+v %v", state.Bindings, err)
	}
	if _, err := nodecore.AddBinding(nodeRoot, bootstrapDir); err != nil {
		t.Fatal(err)
	}
	nodeState, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(nodeState.Bindings) != 1 || nodeState.Bindings[0].InstallationID != state.InstallationID {
		t.Fatalf("node did not import the entrance binding: %+v %v", nodeState.Bindings, err)
	}
	token, err := gatewaycore.ReadNodeToken(root, node.NodeID)
	if err != nil {
		t.Fatal(err)
	}
	delivered, err := os.ReadFile(nodeState.Bindings[0].ControlTokenFile)
	if err != nil || strings.TrimSpace(string(delivered)) != token {
		t.Fatalf("the node does not hold this node's control token: %v", err)
	}
	if entries := entryNames(t, filepath.Join(nodeRoot, "bindings", state.InstallationID)); len(entries) != 1 || entries[0] != "control-token" {
		t.Fatalf("node binding holds %v, want only control-token", entries)
	}
	// One token per node: a machine that leaks what it was given does not hand over
	// the others.
	//
	// The address the first node was given is held here, the way it is held on that
	// machine while the node runs. A second node initialized while it is free would
	// be given the same address, and two nodes at one address answer for each other.
	held, err := net.Listen("tcp4", node.ListenAddress)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	other := filepath.Join(t.TempDir(), "node")
	otherNode, err := nodecore.Initialize(other, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if otherNode.ListenAddress == node.ListenAddress {
		t.Fatalf("the second node was given the first one's address %s", otherNode.ListenAddress)
	}
	if _, err := addLANNode(root, "Laptop", otherNode.NodeID, otherNode.ListenAddress, filepath.Join(t.TempDir(), "bootstrap")); err != nil {
		t.Fatal(err)
	}
	otherToken, err := gatewaycore.ReadNodeToken(root, otherNode.NodeID)
	if err != nil || otherToken == token {
		t.Fatalf("the second node got %q, %v", otherToken, err)
	}
	// An address no gateway could dial is not where a node is.
	if _, err := addLANNode(root, "Desk", node.NodeID, "0.0.0.0:58627", filepath.Join(t.TempDir(), "bootstrap")); err == nil {
		t.Fatal("an unspecified node address was recorded")
	}
	if _, err := addLANNode(root, "Desk", node.NodeID, "10.0.0.1", filepath.Join(t.TempDir(), "bootstrap")); err == nil {
		t.Fatal("a node address without a port was recorded")
	}
	// The same node added again is that node kept up to date: a machine that moved
	// is put back in reach without being recorded twice.
	moved, err := addLANNode(root, "Desk", node.NodeID, "10.0.0.1:58627", filepath.Join(t.TempDir(), "bootstrap"))
	if err != nil {
		t.Fatal(err)
	}
	if moved.NodeAddress != "10.0.0.1:58627" {
		t.Fatalf("moving a node answered %+v", moved)
	}
	state, err = loadLANState(root)
	if err != nil || len(state.Nodes) != 2 || state.Nodes[0].Address != "10.0.0.1:58627" || state.Nodes[1].ID != otherNode.NodeID {
		t.Fatalf("moving a node changed the list: %+v %v", state.Nodes, err)
	}
	// And the entrance can now be opened, serving both of them.
	service, err := openLANService(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(service.State().Nodes) != 2 {
		t.Fatalf("the entrance serves %+v", service.State().Nodes)
	}
}

// Renewing the certificate rotates what clients pinned and touches nothing else:
// the name and address of every node stay, because those are what this entrance
// dials and not what its clients dialed.
func TestLANRenewalAndRepairKeepTheNodes(t *testing.T) {
	nodeRoot := t.TempDir()
	node, err := nodecore.Initialize(nodeRoot, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	first, err := initializeLAN(root, "127.0.0.1", 30)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := addLANNode(root, "Desk", node.NodeID, node.ListenAddress, filepath.Join(t.TempDir(), "bootstrap")); err != nil {
		t.Fatal(err)
	}
	beforeRenewal, err := loadLANState(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{beforeRenewal.LAN.CertificateFile, beforeRenewal.LAN.PrivateKeyFile} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatalf("referenced TLS file %q is unavailable: %v", name, err)
		}
	}
	repaired, err := repairLANPorts(root)
	if err != nil || repaired.InstallationID != first.InstallationID || repaired.CertificateFingerprint != first.CertificateFingerprint {
		t.Fatalf("unexpected port repair: %+v %v", repaired, err)
	}
	repairedOrigin, _ := url.Parse(repaired.Origin)
	if repairedOrigin.Port() == "" || repaired.ListenAddress != "0.0.0.0:"+repairedOrigin.Port() {
		t.Fatalf("repaired origin does not match listen address: %+v", repaired)
	}
	if state, err := loadLANState(root); err != nil || len(state.Nodes) != 1 || state.Nodes[0].Address != node.ListenAddress {
		t.Fatalf("repairing ports moved a node: %+v %v", state.Nodes, err)
	}
	renewed, err := renewLANCertificate(root, 60)
	if err != nil {
		t.Fatal(err)
	}
	// Renewal rotates the certificate clients pinned without touching the identity
	// the nodes bound, and it hands out no invitation: a client that has to be told
	// about the new certificate is told by a new invitation, not by init.
	if renewed.InstallationID != first.InstallationID || renewed.Origin != repaired.Origin || renewed.CertificateFingerprint == first.CertificateFingerprint || renewed.PublicKeyPin == first.PublicKeyPin {
		t.Fatalf("LAN renewal changed installation or did not rotate trust: %+v", renewed)
	}
	afterRenewal, err := loadLANState(root)
	if err != nil {
		t.Fatal(err)
	}
	if afterRenewal.LAN.CertificateFile == beforeRenewal.LAN.CertificateFile || afterRenewal.LAN.PrivateKeyFile == beforeRenewal.LAN.PrivateKeyFile {
		t.Fatal("renewal did not switch the state pointer to a new TLS identity")
	}
	if len(afterRenewal.Nodes) != 1 || afterRenewal.Nodes[0].Address != node.ListenAddress {
		t.Fatalf("renewal lost the node: %+v", afterRenewal.Nodes)
	}
	for _, name := range []string{afterRenewal.LAN.CertificateFile, afterRenewal.LAN.PrivateKeyFile} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatalf("renewed TLS file %q is unavailable: %v", name, err)
		}
	}
	for _, name := range []string{beforeRenewal.LAN.CertificateFile, beforeRenewal.LAN.PrivateKeyFile} {
		if _, err := os.Stat(filepath.Join(root, name)); !os.IsNotExist(err) {
			t.Fatalf("retired TLS file %q still exists or could not be checked: %v", name, err)
		}
	}
	current, err := initializeLAN(root, "127.0.0.1", 60)
	if err != nil || current.CertificateFingerprint != renewed.CertificateFingerprint {
		t.Fatalf("renewed LAN certificate is not current: %+v %v", current, err)
	}
}

// Taking a node out of the entrance takes everything of it with it: the state stops
// serving it, its control token is gone so a machine added again is given a new
// one, and the node machine is left holding a binding that authenticates nothing.
func TestRemoveLANNodeForgetsTheNodeEntirely(t *testing.T) {
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", 30); err != nil {
		t.Fatal(err)
	}
	ids := []string{}
	addresses := map[string]bool{}
	var held []net.Listener
	defer func() {
		for _, listener := range held {
			listener.Close()
		}
	}()
	for index, nodeRoot := range []string{t.TempDir(), t.TempDir()} {
		node, err := nodecore.Initialize(nodeRoot, "127.0.0.1")
		if err != nil {
			t.Fatal(err)
		}
		// Each node keeps the address it was given, so the node initialized after it
		// is given another one: two nodes at one address answer for each other.
		listener, err := net.Listen("tcp4", node.ListenAddress)
		if err != nil {
			t.Fatal(err)
		}
		held = append(held, listener)
		if addresses[node.ListenAddress] {
			t.Fatalf("two nodes were given the same address %s", node.ListenAddress)
		}
		addresses[node.ListenAddress] = true
		ids = append(ids, node.NodeID)
		if _, err := addLANNode(root, []string{"Desk", "Laptop"}[index], node.NodeID, node.ListenAddress, filepath.Join(t.TempDir(), "bootstrap")); err != nil {
			t.Fatal(err)
		}
	}
	removed, err := removeLANNode(root, "Desk")
	if err != nil {
		t.Fatal(err)
	}
	if !removed.OK || removed.NodeID != ids[0] || removed.NodeName != "Desk" || !removed.RestartRequired {
		t.Fatalf("unexpected removal result: %+v", removed)
	}
	if _, err := os.Stat(gatewaycore.NodeTokenPath(root, ids[0])); !os.IsNotExist(err) {
		t.Fatalf("the removed node's control token is still there: %v", err)
	}
	if _, err := os.Stat(gatewaycore.NodeTokenPath(root, ids[1])); err != nil {
		t.Fatalf("removing one node took another's token: %v", err)
	}
	state, err := loadLANState(root)
	if err != nil || len(state.Nodes) != 1 || state.Nodes[0].ID != ids[1] {
		t.Fatalf("the removed state is %+v (%v)", state.Nodes, err)
	}
	if _, err := openLANService(root); err != nil {
		t.Fatalf("the entrance no longer opens: %v", err)
	}
	if _, err := removeLANNode(root, "Desk"); err == nil {
		t.Fatal("removing a node this entrance does not serve was accepted")
	}
	// A node is named by its id just as well: that is what a script has.
	if _, err := removeLANNode(root, ids[1]); err != nil {
		t.Fatal(err)
	}
	// An entrance with nothing behind it is one that cannot be opened, which is what
	// it was before the first node was added.
	if _, err := openLANService(root); err == nil {
		t.Fatal("an entrance serving no node was opened")
	}
}

// Replacing a control token replaces the token and nothing else, and the
// replacement is delivered: the same node, a new token in the bundle that machine
// imports, until it does so answering this entrance only after it is restarted.
func TestRenewLANNodeTokenReplacesTheTokenAndDeliversIt(t *testing.T) {
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", 30); err != nil {
		t.Fatal(err)
	}
	node, err := nodecore.Initialize(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	bootstrapDir := filepath.Join(t.TempDir(), "bootstrap")
	if _, err := addLANNode(root, "Desk", node.NodeID, node.ListenAddress, bootstrapDir); err != nil {
		t.Fatal(err)
	}
	before, err := gatewaycore.ReadNodeToken(root, node.NodeID)
	if err != nil {
		t.Fatal(err)
	}
	result, err := renewLANNodeToken(root, "Desk", bootstrapDir)
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.NodeID != node.NodeID || result.NodeName != "Desk" || result.NodeAddress != node.ListenAddress || !result.RestartRequired {
		t.Fatalf("unexpected renewal result: %+v", result)
	}
	after, err := gatewaycore.ReadNodeToken(root, node.NodeID)
	if err != nil || after == before {
		t.Fatalf("the control token was not replaced: %v", err)
	}
	delivered, err := os.ReadFile(filepath.Join(bootstrapDir, "control-token"))
	if err != nil || strings.TrimSpace(string(delivered)) != after {
		t.Fatalf("the bundle does not carry the new token: %v", err)
	}
	// The node is the same node, and so is the state that records it.
	state, err := loadLANState(root)
	if err != nil || len(state.Nodes) != 1 || state.Nodes[0].ID != node.NodeID || state.Nodes[0].Name != "Desk" {
		t.Fatalf("replacing a token changed the state: %+v (%v)", state.Nodes, err)
	}
	if _, err := renewLANNodeToken(root, strings.Repeat("33", 32), filepath.Join(t.TempDir(), "bootstrap")); err == nil {
		t.Fatal("a token was replaced for a node this entrance does not serve")
	}
}

// 命令行的形状：每个动作都从参数进来。flag 解析错一位，就是一条命令整个不可用。
func TestLANNodeCommandsTakeTheirArguments(t *testing.T) {
	root := t.TempDir()
	if _, err := initializeLAN(root, "127.0.0.1", 30); err != nil {
		t.Fatal(err)
	}
	node, err := nodecore.Initialize(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	bootstrap := filepath.Join(t.TempDir(), "bootstrap")
	run := func(args ...string) string {
		t.Helper()
		var out bytes.Buffer
		if err := runLANNode(args, &out); err != nil {
			t.Fatalf("node %v: %v", args, err)
		}
		return out.String()
	}
	run("add", "--state", root, "--name", "Desk", "--node-id", node.NodeID, "--node-address", node.ListenAddress, "--node-bootstrap", bootstrap)
	if listed := run("list", "--state", root); !strings.Contains(listed, node.NodeID) {
		t.Fatalf("node list is %s", listed)
	}
	if renewed := run("token", "renew", "--state", root, "--node", "Desk", "--node-bootstrap", bootstrap); !strings.Contains(renewed, `"restart_required":true`) {
		t.Fatalf("node token renew is %s", renewed)
	}
	if removed := run("remove", "--state", root, "--node", "Desk"); !strings.Contains(removed, node.NodeID) {
		t.Fatalf("node remove is %s", removed)
	}
	// 一个动作不接受另一个动作的参数，也不接受一个不存在的动作。
	for _, args := range [][]string{
		{"remove", "--state", root, "--node", "Desk", "--name", "Desk"},
		{"token", "renew", "--state", root, "--node", "Desk"},
		{"destroy", "--state", root},
	} {
		var out bytes.Buffer
		if err := runLANNode(args, &out); err == nil {
			t.Fatalf("node %v was accepted", args)
		}
	}
}

func sameNames(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range got {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}
