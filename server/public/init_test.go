package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/netaddr"
	"github.com/hxaxd/remote-everything/internal/nodecore"
)

func TestInitializePublicState(t *testing.T) {
	root := t.TempDir()
	bundleRoot := filepath.Join(t.TempDir(), "bundle")
	first, err := initializePublicState(root, bundleRoot, "https://remote.example.com")
	if err != nil {
		t.Fatal(err)
	}
	if !first.OK || len(first.InstallationID) != 64 || first.DeviceCAFile != filepath.Join(root, "device-issuer.crt.pem") {
		t.Fatalf("unexpected init result: %+v", first)
	}
	bundle, err := deploymentbootstrap.ReadNodeBundle(bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	nodeRoot := filepath.Join(t.TempDir(), "node")
	if _, err := nodecore.Initialize(nodeRoot, "127.0.0.1"); err != nil {
		t.Fatal(err)
	}
	bindResult, err := nodecore.AddBinding(nodeRoot, bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	nodeState, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(nodeState.Bindings) != 1 {
		t.Fatalf("node did not import the gateway binding: %+v %v", nodeState, err)
	}
	binding := nodeState.Bindings[0]
	if bindResult.InstallationID != first.InstallationID || bundle.InstallationID != first.InstallationID {
		t.Fatalf("bootstrap split installation identity: gateway=%s bundle=%s node=%s", first.InstallationID, bundle.InstallationID, bindResult.InstallationID)
	}
	nodeToken, err := os.ReadFile(binding.ControlTokenFile)
	if err != nil || strings.TrimSpace(string(nodeToken)) != bundle.ControlToken {
		t.Fatalf("node did not import gateway control token: %v", err)
	}
	// The node is bound by identity alone: it holds its own binding and nothing
	// of the material the tunnel agent on its machine runs on.
	bindingEntries, err := os.ReadDir(filepath.Join(nodeRoot, "bindings", first.InstallationID))
	if err != nil {
		t.Fatal(err)
	}
	if len(bindingEntries) != 1 || bindingEntries[0].Name() != "control-token" {
		t.Fatalf("node binding holds %v, want only control-token", bindingEntries)
	}
	// The gateway keeps what the tunnel server and the 443 entrance on its own
	// machine read; the tunnel agent's material travels in the handover bundle.
	for _, path := range []string{first.TunnelCAFile, first.FRPSTokenFile} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("gateway does not hold its own tunnel material %s: %v", path, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "tunnel-client.crt.pem")); !os.IsNotExist(err) {
		t.Fatalf("the gateway state root holds the tunnel agent's identity: %v", err)
	}
	if first.TunnelMaterialDir != filepath.Join(bundleRoot, "frpc") {
		t.Fatalf("tunnel material directory is %q", first.TunnelMaterialDir)
	}
	delivered := filepath.Join(bundleRoot, "frpc", "tunnel-client.crt.pem")
	clientCertificate, err := os.ReadFile(delivered)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.TunnelClientFingerprint) != 64 {
		t.Fatalf("init did not report the issued client identity: %+v", first)
	}
	for _, name := range []string{"frps-token", "tunnel-client.key.pem"} {
		if _, err := os.Stat(filepath.Join(first.TunnelMaterialDir, name)); err != nil {
			t.Fatalf("handover bundle is missing %s: %v", name, err)
		}
	}
	if entries := entryNames(t, bundleRoot); len(entries) != 3 {
		t.Fatalf("handover bundle holds %v, want the identity bundle and the material", entries)
	}
	tunnelCA, err := os.ReadFile(first.TunnelCAFile)
	if err != nil {
		t.Fatal(err)
	}
	second, err := initializePublicState(root, bundleRoot, "https://remote.example.com")
	if err != nil || second.InstallationID != first.InstallationID || second.StatusListen != first.StatusListen || second.NodeTunnelListen != first.NodeTunnelListen {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
	reissued, err := os.ReadFile(delivered)
	if err != nil || !bytes.Equal(reissued, clientCertificate) {
		t.Fatalf("re-running init replaced the identity a running tunnel agent authenticates with: %v", err)
	}
	var renewalOutput bytes.Buffer
	if err := renewTunnelIdentity(root, bundleRoot, &renewalOutput); err != nil {
		t.Fatal(err)
	}
	var renewal tunnelRenewResult
	if err := json.Unmarshal(renewalOutput.Bytes(), &renewal); err != nil {
		t.Fatal(err)
	}
	if !renewal.OK || renewal.InstallationID != first.InstallationID || renewal.NodeBootstrap != filepath.Clean(bundleRoot) || renewal.TunnelMaterialDir != first.TunnelMaterialDir || len(renewal.TunnelClientFingerprint) != 64 {
		t.Fatalf("unexpected tunnel renewal result: %+v", renewal)
	}
	renewedCertificate, err := os.ReadFile(delivered)
	if err != nil || bytes.Equal(renewedCertificate, clientCertificate) {
		t.Fatalf("renewal did not rotate the tunnel client identity: %v", err)
	}
	if renewedCertificate == nil {
		t.Fatal("renewal left no certificate")
	}
	unchangedCA, err := os.ReadFile(renewal.TunnelCAFile)
	if err != nil || !bytes.Equal(unchangedCA, tunnelCA) {
		t.Fatalf("renewal changed the tunnel CA: %v", err)
	}
	// Renewal is gateway-side only: the node keeps the binding it already had.
	unchangedNode, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(unchangedNode.Bindings) != 1 || unchangedNode.Bindings[0] != binding {
		t.Fatalf("tunnel renewal changed the node binding: %+v %v", unchangedNode.Bindings, err)
	}
	addresses := []string{first.StatusListen, first.PairingListen, first.FRPSListen, first.NodeTunnelListen}
	seen := map[string]bool{}
	for _, address := range addresses {
		if !netaddr.ValidLoopback(address) || seen[address] {
			t.Fatalf("invalid or duplicate address: %q", address)
		}
		seen[address] = true
	}
	// The state every gateway keeps is the same shape: identity plus named
	// listeners, which is what the CLI and the deployment templates address.
	stored := filepath.Join(root, "server.json")
	state, err := gatewaycore.LoadState(stored)
	if err != nil {
		t.Fatal(err)
	}
	for name, reported := range map[string]string{"status": first.StatusListen, "pairing": first.PairingListen, "frps": first.FRPSListen, "node_tunnel": first.NodeTunnelListen} {
		if address, err := state.Address(name); err != nil || address != reported {
			t.Fatalf("listener %s = %q, %v; init reported %q", name, address, err, reported)
		}
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{paths.stateFile, gatewaycore.ControlTokenPath(root), devicecore.IssuerCertPath(root)} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("missing state file %s: %v", path, err)
		}
	}
	for _, obsolete := range []string{"pairing-password", "client-trust.pem", "approved-clients"} {
		if _, err := os.Stat(filepath.Join(root, obsolete)); !os.IsNotExist(err) {
			t.Fatalf("obsolete state was created: %s", obsolete)
		}
	}
	var output bytes.Buffer
	if err := repairPublicPorts(root, &output); err != nil {
		t.Fatal(err)
	}
	repaired, err := gatewaycore.LoadState(stored)
	if err != nil || repaired.InstallationID != first.InstallationID {
		t.Fatalf("port repair changed identity: %+v %v", repaired, err)
	}
	seen = map[string]bool{}
	for _, name := range []string{"status", "pairing", "frps", "node_tunnel"} {
		address, err := repaired.Address(name)
		if err != nil || !netaddr.ValidLoopback(address) || seen[address] {
			t.Fatalf("invalid repaired address for %s: %q %v", name, address, err)
		}
		seen[address] = true
	}
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
