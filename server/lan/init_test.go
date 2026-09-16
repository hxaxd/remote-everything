package main

import (
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"testing"

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
// never reads the node's, and the node it serves is a separate service that may
// well be a separate machine. The two meet only through the identity bundle the
// node imports.
func TestInitializeLAN(t *testing.T) {
	nodeRoot := t.TempDir()
	node, err := nodecore.Initialize(nodeRoot, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	bootstrapDir := filepath.Join(t.TempDir(), "bootstrap")
	first, err := initializeLAN(root, node.ListenAddress, "127.0.0.1", 30, bootstrapDir)
	if err != nil {
		t.Fatal(err)
	}
	origin, parseErr := url.Parse(first.GatewayOrigin)
	if !first.OK || parseErr != nil || origin.Scheme != "https" || origin.Hostname() != "127.0.0.1" || origin.Port() == "" || len(first.CertificateFingerprint) != 64 || len(first.InstallationID) != 64 {
		t.Fatalf("unexpected init result: %+v", first)
	}
	initial, err := loadLANState(root)
	if err != nil {
		t.Fatal(err)
	}
	if initial.NodeAddress != node.ListenAddress {
		t.Fatalf("entrance did not record where its node is: %+v", initial)
	}
	want := []string{"control-token", "lan.json", initial.CertificateFile, initial.PrivateKeyFile}
	sort.Strings(want)
	if entries := entryNames(t, root); !sameNames(entries, want) {
		t.Fatalf("entrance root holds %v, want %v", entries, want)
	}
	// The node knows nothing about the entrance until it imports the bundle the
	// entrance produced.
	if state, err := nodecore.LoadState(nodeRoot); err != nil || len(state.Bindings) != 0 {
		t.Fatalf("the entrance reached into the node state: %+v %v", state.Bindings, err)
	}
	if _, err := nodecore.AddBinding(nodeRoot, bootstrapDir); err != nil {
		t.Fatal(err)
	}
	nodeState, err := nodecore.LoadState(nodeRoot)
	if err != nil || len(nodeState.Bindings) != 1 || nodeState.Bindings[0].InstallationID != first.InstallationID {
		t.Fatalf("node did not import the entrance binding: %+v %v", nodeState.Bindings, err)
	}
	if entries := entryNames(t, filepath.Join(nodeRoot, "bindings", first.InstallationID)); len(entries) != 1 || entries[0] != "control-token" {
		t.Fatalf("node binding holds %v, want only control-token", entries)
	}
	second, err := initializeLAN(root, node.ListenAddress, "127.0.0.1", 30, bootstrapDir)
	if err != nil || second.CertificateFingerprint != first.CertificateFingerprint {
		t.Fatalf("init is not idempotent: %+v %v", second, err)
	}
	if _, err := initializeLAN(root, node.ListenAddress, "localhost", 30, bootstrapDir); err == nil {
		t.Fatal("accepted an existing certificate for a different host")
	}
	if _, err := initializeLAN(root, node.ListenAddress, "::1", 30, bootstrapDir); err == nil {
		t.Fatal("accepted an IPv6 host while the LAN service is IPv4-only")
	}
	if _, err := initializeLAN(root, "127.0.0.1:9", "127.0.0.1", 30, bootstrapDir); err == nil {
		t.Fatal("accepted a node address no gateway could dial")
	}
	// The node's address is configuration: a node that moved is put back in reach
	// without disturbing the identity clients were paired with.
	moved, err := initializeLAN(root, "10.0.0.1:58627", "127.0.0.1", 30, bootstrapDir)
	if err != nil || moved.InstallationID != first.InstallationID || moved.CertificateFingerprint != first.CertificateFingerprint {
		t.Fatalf("moving the node changed the entrance identity: %+v %v", moved, err)
	}
	if movedState, err := loadLANState(root); err != nil || movedState.NodeAddress != "10.0.0.1:58627" {
		t.Fatalf("entrance did not record the new node address: %+v %v", movedState, err)
	}
	beforeRenewal, err := loadLANState(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{beforeRenewal.CertificateFile, beforeRenewal.PrivateKeyFile} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatalf("referenced TLS file %q is unavailable: %v", name, err)
		}
	}
	repaired, err := repairLANPorts(root)
	if err != nil || repaired.InstallationID != first.InstallationID || repaired.CertificateFingerprint != first.CertificateFingerprint {
		t.Fatalf("unexpected port repair: %+v %v", repaired, err)
	}
	repairedOrigin, _ := url.Parse(repaired.GatewayOrigin)
	if repairedOrigin.Port() == "" || repaired.ListenAddress != "0.0.0.0:"+repairedOrigin.Port() {
		t.Fatalf("repaired origin does not match listen address: %+v", repaired)
	}
	renewed, err := renewLANCertificate(root, 60, "Test PC", "")
	if err != nil {
		t.Fatal(err)
	}
	if renewed.InstallationID != first.InstallationID || renewed.GatewayOrigin != repaired.GatewayOrigin || renewed.CertificateFingerprint == first.CertificateFingerprint || renewed.SetupURI == "" {
		t.Fatalf("LAN renewal changed installation or did not rotate trust: %+v", renewed)
	}
	afterRenewal, err := loadLANState(root)
	if err != nil {
		t.Fatal(err)
	}
	if afterRenewal.CertificateFile == beforeRenewal.CertificateFile || afterRenewal.PrivateKeyFile == beforeRenewal.PrivateKeyFile {
		t.Fatal("renewal did not switch the state pointer to a new TLS identity")
	}
	if afterRenewal.NodeAddress != "10.0.0.1:58627" {
		t.Fatalf("renewal lost the node address: %+v", afterRenewal)
	}
	for _, name := range []string{afterRenewal.CertificateFile, afterRenewal.PrivateKeyFile} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatalf("renewed TLS file %q is unavailable: %v", name, err)
		}
	}
	for _, name := range []string{beforeRenewal.CertificateFile, beforeRenewal.PrivateKeyFile} {
		if _, err := os.Stat(filepath.Join(root, name)); !os.IsNotExist(err) {
			t.Fatalf("retired TLS file %q still exists or could not be checked: %v", name, err)
		}
	}
	current, err := initializeLAN(root, "10.0.0.1:58627", "127.0.0.1", 60, bootstrapDir)
	if err != nil || current.CertificateFingerprint != renewed.CertificateFingerprint {
		t.Fatalf("renewed LAN certificate is not current: %+v %v", current, err)
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
