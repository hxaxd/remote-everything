package main

import (
	"bytes"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/netaddr"
	"github.com/hxaxd/remote-everything/internal/nodecore"
)

func TestInitializePublicState(t *testing.T) {
	root := t.TempDir()
	bundleRoot := filepath.Join(t.TempDir(), "bundle")
	first, err := initializePublicState(root, bundleRoot)
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
	if _, err := nodecore.Initialize(nodeRoot); err != nil {
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
	// The node is bound by identity alone: the tunnel material stays with the
	// gateway that owns the tunnel, and none of it travels in the node bundle.
	bindingEntries, err := os.ReadDir(filepath.Join(nodeRoot, "bindings", first.InstallationID))
	if err != nil {
		t.Fatal(err)
	}
	if len(bindingEntries) != 1 || bindingEntries[0].Name() != "control-token" {
		t.Fatalf("node binding holds %v, want only control-token", bindingEntries)
	}
	for _, path := range []string{first.TunnelCAFile, first.FRPSTokenFile, first.TunnelClientCert, first.TunnelClientKey} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("gateway does not hold its own tunnel material %s: %v", path, err)
		}
		if _, err := os.Stat(filepath.Join(bundleRoot, filepath.Base(path))); !os.IsNotExist(err) {
			t.Fatalf("tunnel material %s travelled in the node bundle: %v", filepath.Base(path), err)
		}
	}
	clientCertificate, err := os.ReadFile(first.TunnelClientCert)
	if err != nil {
		t.Fatal(err)
	}
	tunnelCA, err := os.ReadFile(first.TunnelCAFile)
	if err != nil {
		t.Fatal(err)
	}
	second, err := initializePublicState(root, bundleRoot)
	if err != nil || second.InstallationID != first.InstallationID || second.StatusListen != first.StatusListen || second.NodeTunnelListen != first.NodeTunnelListen {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
	reissued, err := os.ReadFile(second.TunnelClientCert)
	if err != nil || !bytes.Equal(reissued, clientCertificate) {
		t.Fatalf("re-running init replaced the identity a running tunnel agent authenticates with: %v", err)
	}
	var renewalOutput bytes.Buffer
	if err := renewTunnelIdentity(root, &renewalOutput); err != nil {
		t.Fatal(err)
	}
	var renewal tunnelRenewResult
	if err := json.Unmarshal(renewalOutput.Bytes(), &renewal); err != nil {
		t.Fatal(err)
	}
	if !renewal.OK || renewal.InstallationID != first.InstallationID || renewal.TunnelClientCert != first.TunnelClientCert || renewal.TunnelClientFingerprint == "" {
		t.Fatalf("unexpected tunnel renewal result: %+v", renewal)
	}
	renewedCertificate, err := os.ReadFile(renewal.TunnelClientCert)
	if err != nil || bytes.Equal(renewedCertificate, clientCertificate) {
		t.Fatalf("renewal did not rotate the tunnel client identity: %v", err)
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
	paths, err := newPublicPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{paths.stateFile, gatewaycore.ControlTokenPath(root), paths.issuerKeyFile, paths.issuerCertFile} {
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
	repaired, err := paths.loadState()
	if err != nil || repaired.InstallationID != first.InstallationID {
		t.Fatalf("port repair changed identity: %+v %v", repaired, err)
	}
	seen = map[string]bool{}
	for _, address := range []string{repaired.StatusListen, repaired.PairingListen, repaired.FRPSListen, repaired.NodeTunnelListen} {
		if !netaddr.ValidLoopback(address) || seen[address] {
			t.Fatalf("invalid repaired address: %q", address)
		}
		seen[address] = true
	}
}

func TestLoadIssuerRejectsTamperedSelfSignature(t *testing.T) {
	root := t.TempDir()
	if _, err := initializePublicState(root, filepath.Join(t.TempDir(), "bundle")); err != nil {
		t.Fatal(err)
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(paths.issuerCertFile)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(contents)
	if block == nil || len(block.Bytes) == 0 {
		t.Fatal("issuer certificate could not be decoded")
	}
	block.Bytes[len(block.Bytes)-1] ^= 0x01
	if err := os.WriteFile(paths.issuerCertFile, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := loadIssuer(paths); err == nil {
		t.Fatal("issuer with a tampered self-signature was accepted")
	}
}
