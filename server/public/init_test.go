package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/netaddr"
	"github.com/hxaxd/remote-everything/internal/nodecore"
	"github.com/hxaxd/remote-everything/internal/tunnelbootstrap"
)

// init records the gateway itself: its identity, its origin, its listeners and the
// material its own tunnel and the 443 entrance in front of it read. What it does
// not create is a node: a node is added afterwards, one at a time, because each one
// is handed over to a machine of its own.
func TestInitializePublicState(t *testing.T) {
	root := t.TempDir()
	first, err := initializePublicState(root, "https://remote.example.com")
	if err != nil {
		t.Fatal(err)
	}
	if !first.OK || len(first.InstallationID) != 64 || first.DeviceCAFile != filepath.Join(root, "device-issuer.crt.pem") {
		t.Fatalf("unexpected init result: %+v", first)
	}
	stored := filepath.Join(root, "server.json")
	state, err := gatewaycore.LoadState(stored)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Nodes) != 0 {
		t.Fatalf("init recorded nodes: %+v", state.Nodes)
	}
	for name, reported := range map[string]string{"status": first.StatusListen, "pairing": first.PairingListen, "frps": first.FRPSListen} {
		if address, err := state.Address(name); err != nil || address != reported || !netaddr.ValidLoopback(address) {
			t.Fatalf("listener %s = %q, %v; init reported %q", name, address, err, reported)
		}
	}
	seen := map[string]bool{}
	for _, address := range []string{first.StatusListen, first.PairingListen, first.FRPSListen} {
		if seen[address] {
			t.Fatalf("duplicate address: %q", address)
		}
		seen[address] = true
	}
	// The gateway keeps what the tunnel server and the 443 entrance on its own
	// machine read; a tunnel agent's identity travels with the node it belongs to.
	for _, path := range []string{first.TunnelCAFile, first.FRPSTokenFile, gatewaycore.NodeTokenPath(root, strings.Repeat("11", 32)), devicecore.IssuerCertPath(root)} {
		if path == gatewaycore.NodeTokenPath(root, strings.Repeat("11", 32)) {
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("init minted a node's control token: %v", err)
			}
			continue
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("gateway does not hold its own material %s: %v", path, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "tunnel-client.crt.pem")); !os.IsNotExist(err) {
		t.Fatalf("the gateway state root holds the tunnel agent's identity: %v", err)
	}
	for _, obsolete := range []string{"pairing-password", "client-trust.pem", "approved-clients", "control-token"} {
		if _, err := os.Stat(filepath.Join(root, obsolete)); !os.IsNotExist(err) {
			t.Fatalf("obsolete state was created: %s", obsolete)
		}
	}
	// A gateway that serves no node is not one to start: it has nothing to route a
	// request to.
	if _, err := openPublicService(root); err == nil {
		t.Fatal("a gateway with no node was opened")
	}
	tunnelCA, err := os.ReadFile(first.TunnelCAFile)
	if err != nil {
		t.Fatal(err)
	}
	second, err := initializePublicState(root, "https://remote.example.com")
	if err != nil || second.InstallationID != first.InstallationID || second.StatusListen != first.StatusListen || second.FRPSListen != first.FRPSListen {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
	if unchanged, err := os.ReadFile(second.TunnelCAFile); err != nil || !bytes.Equal(unchanged, tunnelCA) {
		t.Fatalf("re-running init replaced the tunnel CA: %v", err)
	}
	if _, err := initializePublicState(root, "https://other.example.com"); err == nil {
		t.Fatal("init accepted another origin for an existing gateway")
	}
}

// Adding a node records where this gateway reaches it and hands that machine the
// identity bundle it binds this gateway with, which is the whole of what an
// operator carries across.
func TestAddPublicNodeDeliversOneNode(t *testing.T) {
	root := t.TempDir()
	gateway, err := initializePublicState(root, "https://remote.example.com")
	if err != nil {
		t.Fatal(err)
	}
	nodeID := strings.Repeat("11", 32)
	bundleRoot := filepath.Join(t.TempDir(), "bundle")
	added, err := addPublicNode(root, "Desk", nodeID, "", bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	if !added.OK || added.NodeID != nodeID || added.NodeName != "Desk" || added.NodeBootstrap != filepath.Clean(bundleRoot) || !added.RestartRequired {
		t.Fatalf("unexpected node result: %+v", added)
	}
	// Where this gateway reaches the node is a loopback port of its own tunnel, and
	// the port in it is what that machine's tunnel agent has to publish.
	if !netaddr.ValidLoopback(added.NodeAddress) {
		t.Fatalf("the node is at %q", added.NodeAddress)
	}
	if added.TunnelMaterialDir != filepath.Join(bundleRoot, tunnelbootstrap.TunnelMaterialDir) {
		t.Fatalf("tunnel material directory is %q", added.TunnelMaterialDir)
	}
	for _, name := range []string{"frps-token", "tunnel-client.key.pem", "tunnel-client.crt.pem"} {
		if _, err := os.Stat(filepath.Join(added.TunnelMaterialDir, name)); err != nil {
			t.Fatalf("handover bundle is missing %s: %v", name, err)
		}
	}
	if len(added.TunnelClientFingerprint) != 64 {
		t.Fatalf("the issued client identity was not reported: %+v", added)
	}
	// The node imports the bundle with binding add, and what it holds is the token
	// this gateway minted for that node and no other.
	bundle, err := deploymentbootstrap.ReadNodeBundle(bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	token, err := gatewaycore.ReadNodeToken(root, nodeID)
	if err != nil || bundle.ControlToken != token {
		t.Fatalf("the bundle does not carry this node's control token: %v", err)
	}
	nodeRoot := filepath.Join(t.TempDir(), "node")
	if _, err := nodecore.Initialize(nodeRoot, "127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := nodecore.AddBinding(nodeRoot, bundleRoot); err != nil {
		t.Fatal(err)
	}
	nodeState, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(nodeState.Bindings) != 1 || nodeState.Bindings[0].InstallationID != gateway.InstallationID {
		t.Fatalf("node did not import the gateway binding: %+v %v", nodeState, err)
	}
	// The node is bound by identity alone: it holds its own binding and nothing of
	// the material the tunnel agent on its machine runs on.
	bindingEntries := entryNames(t, filepath.Join(nodeRoot, "bindings", nodeState.Bindings[0].InstallationID))
	if len(bindingEntries) != 1 || bindingEntries[0] != "control-token" {
		t.Fatalf("node binding holds %v, want only control-token", bindingEntries)
	}
	// Adding one more node gives it an address of its own, and the gateway is now
	// one that can be opened.
	other, err := addPublicNode(root, "Laptop", strings.Repeat("22", 32), "", filepath.Join(t.TempDir(), "bundle"))
	if err != nil {
		t.Fatal(err)
	}
	if other.NodeAddress == added.NodeAddress {
		t.Fatalf("two nodes were given one address: %q", other.NodeAddress)
	}
	service, err := openPublicService(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(service.State().Nodes) != 2 {
		t.Fatalf("the gateway serves %+v", service.State().Nodes)
	}
	// Renewing the tunnel identity rotates what the tunnel agent authenticates with
	// and keeps the CA: only that agent has to be pointed at the new files.
	renewal, err := renewTunnelIdentity(root, bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	if !renewal.OK || renewal.InstallationID != service.State().InstallationID || renewal.TunnelMaterialDir != added.TunnelMaterialDir ||
		renewal.TunnelClientFingerprint == added.TunnelClientFingerprint {
		t.Fatalf("unexpected tunnel renewal result: %+v", renewal)
	}
	if unchanged, err := os.ReadFile(renewal.TunnelCAFile); err != nil || !bytes.Equal(unchanged, mustRead(t, filepath.Join(root, tunnelbootstrap.TunnelCACertName))) {
		t.Fatalf("renewal changed the tunnel CA: %v", err)
	}
	// The node keeps the binding it already had.
	unchangedNode, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(unchangedNode.Bindings) != 1 || unchangedNode.Bindings[0] != nodeState.Bindings[0] {
		t.Fatalf("tunnel renewal changed the node binding: %+v %v", unchangedNode.Bindings, err)
	}
}

// Port repair moves every port this gateway owns — its listeners and each node's
// tunnel port — and keeps every identity: the node ids and names stay, so a frpc
// configuration keeps its name and only the port moves.
func TestRepairPublicPortsMovesPortsAndKeepsIdentities(t *testing.T) {
	root := t.TempDir()
	if _, err := initializePublicState(root, "https://remote.example.com"); err != nil {
		t.Fatal(err)
	}
	for index, id := range []string{strings.Repeat("11", 32), strings.Repeat("22", 32)} {
		if _, err := addPublicNode(root, []string{"Desk", "Laptop"}[index], id, "", filepath.Join(t.TempDir(), "bundle")); err != nil {
			t.Fatal(err)
		}
	}
	before, err := gatewaycore.LoadState(filepath.Join(root, "server.json"))
	if err != nil {
		t.Fatal(err)
	}
	repaired, err := repairPublicPorts(root)
	if err != nil {
		t.Fatal(err)
	}
	if !repaired.OK || repaired.InstallationID != before.InstallationID || !repaired.RestartRequired {
		t.Fatalf("unexpected repair result: %+v", repaired)
	}
	if len(repaired.Nodes) != len(before.Nodes) {
		t.Fatalf("repair changed how many nodes there are: %+v", repaired.Nodes)
	}
	seen := map[string]bool{}
	for index, node := range repaired.Nodes {
		if node.ID != before.Nodes[index].ID || node.Name != before.Nodes[index].Name || !netaddr.ValidLoopback(node.Address) {
			t.Fatalf("repair changed node %d: %+v", index, node)
		}
		if seen[node.Address] {
			t.Fatalf("two nodes were given one address: %q", node.Address)
		}
		seen[node.Address] = true
	}
	for _, address := range []string{repaired.StatusListen, repaired.PairingListen, repaired.FRPSListen} {
		if !netaddr.ValidLoopback(address) || seen[address] {
			t.Fatalf("invalid or duplicate repaired listener: %q", address)
		}
		seen[address] = true
	}
	stored, err := gatewaycore.LoadState(filepath.Join(root, "server.json"))
	if err != nil || len(stored.Nodes) != 2 || stored.InstallationID != before.InstallationID {
		t.Fatalf("repaired state is %+v (%v)", stored, err)
	}
}

// Taking a node out of the gateway takes everything of it with it: the state stops
// serving it, its control token is gone so a machine added again is given a new
// one, and no device is left holding a machine that is not there.
func TestRemovePublicNodeForgetsTheNodeEntirely(t *testing.T) {
	root := t.TempDir()
	if _, err := initializePublicState(root, "https://remote.example.com"); err != nil {
		t.Fatal(err)
	}
	first, second := strings.Repeat("11", 32), strings.Repeat("22", 32)
	for index, id := range []string{first, second} {
		if _, err := addPublicNode(root, []string{"Desk", "Laptop"}[index], id, "", filepath.Join(t.TempDir(), "bundle")); err != nil {
			t.Fatal(err)
		}
	}
	removed, err := removePublicNode(root, "Desk")
	if err != nil {
		t.Fatal(err)
	}
	if !removed.OK || removed.NodeID != first || removed.NodeName != "Desk" || len(removed.Devices) != 0 || !removed.RestartRequired {
		t.Fatalf("unexpected removal result: %+v", removed)
	}
	if _, err := os.Stat(gatewaycore.NodeTokenPath(root, first)); !os.IsNotExist(err) {
		t.Fatalf("the removed node's control token is still there: %v", err)
	}
	if _, err := os.Stat(gatewaycore.NodeTokenPath(root, second)); err != nil {
		t.Fatalf("removing one node took another's token: %v", err)
	}
	state, err := gatewaycore.LoadState(filepath.Join(root, "server.json"))
	if err != nil || len(state.Nodes) != 1 || state.Nodes[0].ID != second {
		t.Fatalf("the removed state is %+v (%v)", state.Nodes, err)
	}
	service, err := openPublicService(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := service.State().FindNode(first); ok {
		t.Fatal("the gateway still serves the node that was removed")
	}
	if _, err := removePublicNode(root, "Desk"); err == nil {
		t.Fatal("removing a node this gateway does not serve was accepted")
	}
	// A node is named by its id just as well: that is what a script has.
	if _, err := removePublicNode(root, second); err != nil {
		t.Fatal(err)
	}
	if state, err := gatewaycore.LoadState(filepath.Join(root, "server.json")); err != nil || len(state.Nodes) != 0 {
		t.Fatalf("the gateway serves %+v (%v)", state.Nodes, err)
	}
}

// Replacing a control token replaces the token and nothing else, and the
// replacement is delivered: the same node, a new token in the bundle that machine
// imports, until it does so answering this gateway only after it is restarted.
func TestRenewPublicNodeTokenReplacesTheTokenAndDeliversIt(t *testing.T) {
	root := t.TempDir()
	if _, err := initializePublicState(root, "https://remote.example.com"); err != nil {
		t.Fatal(err)
	}
	nodeID := strings.Repeat("11", 32)
	bundleRoot := filepath.Join(t.TempDir(), "bundle")
	if _, err := addPublicNode(root, "Desk", nodeID, "", bundleRoot); err != nil {
		t.Fatal(err)
	}
	before, err := gatewaycore.ReadNodeToken(root, nodeID)
	if err != nil {
		t.Fatal(err)
	}
	result, err := renewPublicNodeToken(root, "Desk", bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	if !result.OK || result.NodeID != nodeID || result.NodeName != "Desk" || !result.RestartRequired {
		t.Fatalf("unexpected renewal result: %+v", result)
	}
	after, err := gatewaycore.ReadNodeToken(root, nodeID)
	if err != nil || after == before {
		t.Fatalf("the control token was not replaced: %v", err)
	}
	bundle, err := deploymentbootstrap.ReadNodeBundle(bundleRoot)
	if err != nil || bundle.ControlToken != after {
		t.Fatalf("the bundle does not carry the new token: %+v (%v)", bundle, err)
	}
	// The node is the same node, and so is the state that records it.
	state, err := gatewaycore.LoadState(filepath.Join(root, "server.json"))
	if err != nil || len(state.Nodes) != 1 || state.Nodes[0].ID != nodeID {
		t.Fatalf("replacing a token changed the state: %+v (%v)", state.Nodes, err)
	}
	if _, err := renewPublicNodeToken(root, strings.Repeat("33", 32), filepath.Join(t.TempDir(), "bundle")); err == nil {
		t.Fatal("a token was replaced for a node this gateway does not serve")
	}
}

// 命令行的形状：每个动作都从参数进来。flag 解析错一位，就是一条命令整个不可用。
func TestPublicNodeCommandsTakeTheirArguments(t *testing.T) {
	root := t.TempDir()
	if _, err := initializePublicState(root, "https://remote.example.com"); err != nil {
		t.Fatal(err)
	}
	nodeID := strings.Repeat("11", 32)
	bootstrap := filepath.Join(t.TempDir(), "bundle")
	run := func(args ...string) string {
		t.Helper()
		var out bytes.Buffer
		if err := runPublicNode(args, &out); err != nil {
			t.Fatalf("node %v: %v", args, err)
		}
		return out.String()
	}
	run("add", "--state", root, "--name", "Desk", "--node-id", nodeID, "--node-bootstrap", bootstrap)
	if listed := run("list", "--state", root); !strings.Contains(listed, nodeID) {
		t.Fatalf("node list is %s", listed)
	}
	if renewed := run("token", "renew", "--state", root, "--node", "Desk", "--node-bootstrap", bootstrap); !strings.Contains(renewed, `"restart_required":true`) {
		t.Fatalf("node token renew is %s", renewed)
	}
	if removed := run("remove", "--state", root, "--node", "Desk"); !strings.Contains(removed, nodeID) {
		t.Fatalf("node remove is %s", removed)
	}
	// Where this gateway reaches a node is its own tunnel: a pointer from the
	// operator is not an address a public gateway would dial.
	shell := &publicNodes{root: root}
	if _, err := shell.State(); err != nil {
		t.Fatal(err)
	}
	if _, _, err := shell.PlaceNode(strings.Repeat("33", 32), "10.0.0.1:58627"); err == nil {
		t.Fatal("a node address was accepted where every node arrives over the tunnel")
	}
	for _, args := range [][]string{
		{"remove", "--state", root, "--node", "Desk", "--name", "Desk"},
		{"token", "renew", "--state", root, "--node", "Desk"},
		{"destroy", "--state", root},
	} {
		var out bytes.Buffer
		if err := runPublicNode(args, &out); err == nil {
			t.Fatalf("node %v was accepted", args)
		}
	}
}

func mustRead(t *testing.T, path string) []byte {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return contents
}

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
	return names
}
