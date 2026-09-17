package devicecore

import (
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A device CA whose self-signature does not check out must be refused, not
// silently trusted: every device credential a gateway accepts is signed by it.
func TestLoadIssuerRejectsTamperedSelfSignature(t *testing.T) {
	root := t.TempDir()
	if _, err := EnsureIssuer(root); err != nil {
		t.Fatal(err)
	}
	certFile := IssuerCertPath(root)
	contents, err := os.ReadFile(certFile)
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(contents)
	if block == nil || len(block.Bytes) == 0 {
		t.Fatal("issuer certificate could not be decoded")
	}
	block.Bytes[len(block.Bytes)-1] ^= 0x01
	if err := os.WriteFile(certFile, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureIssuer(root); err == nil {
		t.Fatal("issuer with a tampered self-signature was accepted")
	}
}

func TestOpenCreatesTheTrustAndRefusesHalfAnIdentity(t *testing.T) {
	root := t.TempDir()
	node := stubGateway(t)
	trust, err := Open(Config{Root: root, InstallationID: strings.Repeat("a", 64), Origin: "https://remote.example.com", Node: node})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(trust.devicesDir); err != nil {
		t.Fatalf("device records directory is missing: %v", err)
	}
	if _, err := os.Stat(trust.invitesDir); err != nil {
		t.Fatalf("invitations directory is missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "device-issuer.crt.pem")); err != nil {
		t.Fatalf("device CA is missing: %v", err)
	}
	// A gateway without an installation id has nothing to bind devices to.
	if _, err := Open(Config{Root: root, Node: node}); err == nil {
		t.Fatal("a trust without an installation id was opened")
	}
	if _, err := Open(Config{Root: root, InstallationID: strings.Repeat("a", 64), Node: node}); err == nil {
		t.Fatal("a trust without the origin its clients dial was opened")
	}
}
