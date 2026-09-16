package main

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"github.com/hxaxd/remote-everything/internal/nodecore"
)

func TestInitializeLAN(t *testing.T) {
	root := t.TempDir()
	if _, err := nodecore.Initialize(root); err != nil {
		t.Fatal(err)
	}
	first, err := initializeLAN(root, "127.0.0.1", 30)
	if err != nil {
		t.Fatal(err)
	}
	origin, parseErr := url.Parse(first.GatewayOrigin)
	if !first.OK || parseErr != nil || origin.Scheme != "https" || origin.Hostname() != "127.0.0.1" || origin.Port() == "" || len(first.CertificateFingerprint) != 64 || len(first.InstallationID) != 64 {
		t.Fatalf("unexpected init result: %+v", first)
	}
	nodeState, err := nodecore.LoadState(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(nodeState.Bindings) != 1 || nodeState.Bindings[0].InstallationID != first.InstallationID {
		t.Fatalf("LAN init did not register a node binding: %+v", nodeState.Bindings)
	}
	// A LAN entrance has no tunnel, so neither side of the binding may hold
	// anything beyond the control token the entrance authenticates with.
	bindingEntries, err := os.ReadDir(filepath.Join(root, "bindings", first.InstallationID))
	if err != nil {
		t.Fatal(err)
	}
	if len(bindingEntries) != 1 || bindingEntries[0].Name() != "control-token" {
		t.Fatalf("LAN binding holds %v, want only control-token", bindingEntries)
	}
	gatewayEntries, err := os.ReadDir(lanGatewayRoot(root))
	if err != nil {
		t.Fatal(err)
	}
	if len(gatewayEntries) != 1 || gatewayEntries[0].Name() != "control-token" {
		t.Fatalf("LAN gateway directory holds %v, want only control-token", gatewayEntries)
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
	current, err := initializeLAN(root, "127.0.0.1", 60)
	if err != nil || current.CertificateFingerprint != renewed.CertificateFingerprint {
		t.Fatalf("renewed LAN certificate is not current: %+v %v", current, err)
	}
}
