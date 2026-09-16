package main

import (
	"bytes"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
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
	for _, path := range []string{binding.FRPSTokenFile, binding.CACertFile, binding.ClientCertFile, binding.ClientKeyFile} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("node did not import tunnel material %s: %v", path, err)
		}
	}
	oldClientCertificate, err := os.ReadFile(binding.ClientCertFile)
	if err != nil {
		t.Fatal(err)
	}
	renewedBundleRoot := filepath.Join(t.TempDir(), "renewed-bundle")
	var renewalOutput bytes.Buffer
	if err := renewTunnelIdentity(root, renewedBundleRoot, &renewalOutput); err != nil {
		t.Fatal(err)
	}
	renewedBundle, err := deploymentbootstrap.ReadNodeBundle(renewedBundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(renewedBundle.ClientCert, bundle.ClientCert) || !bytes.Equal(renewedBundle.CACertificate, bundle.CACertificate) || renewedBundle.FRPSToken != bundle.FRPSToken {
		t.Fatal("tunnel renewal did not rotate only the client identity")
	}
	if _, err := nodecore.AddBinding(nodeRoot, renewedBundleRoot); err != nil {
		t.Fatal(err)
	}
	renewedState, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(renewedState.Bindings) != 1 {
		t.Fatalf("renewal changed the binding count: %+v %v", renewedState, err)
	}
	renewedBinding := renewedState.Bindings[0]
	newClientCertificate, err := os.ReadFile(renewedBinding.ClientCertFile)
	if err != nil || renewedBinding.ClientCertFile == binding.ClientCertFile || bytes.Equal(newClientCertificate, oldClientCertificate) || !bytes.Equal(newClientCertificate, renewedBundle.ClientCert) {
		t.Fatalf("node did not import renewed tunnel identity: %v", err)
	}
	unchangedOldCertificate, err := os.ReadFile(binding.ClientCertFile)
	if err != nil || !bytes.Equal(unchangedOldCertificate, oldClientCertificate) {
		t.Fatalf("renewal damaged the still-referenced old tunnel identity: %v", err)
	}
	addresses := []string{first.StatusListen, first.PairingListen, first.FRPSListen, first.NodeTunnelListen}
	seen := map[string]bool{}
	for _, address := range addresses {
		if !validPublicLoopback(address) || seen[address] {
			t.Fatalf("invalid or duplicate address: %q", address)
		}
		seen[address] = true
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{paths.stateFile, paths.controlTokenFile, paths.issuerKeyFile, paths.issuerCertFile} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("missing state file %s: %v", path, err)
		}
	}
	for _, obsolete := range []string{"pairing-password", "client-trust.pem", "approved-clients"} {
		if _, err := os.Stat(filepath.Join(root, obsolete)); !os.IsNotExist(err) {
			t.Fatalf("obsolete state was created: %s", obsolete)
		}
	}
	second, err := initializePublicState(root, bundleRoot)
	if err != nil || second.InstallationID != first.InstallationID || second.StatusListen != first.StatusListen || second.NodeTunnelListen != first.NodeTunnelListen {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
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
		if !validPublicLoopback(address) || seen[address] {
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
