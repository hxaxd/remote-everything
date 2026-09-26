package tunnelbootstrap

import (
	"bytes"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func readCertificate(t *testing.T, path string) *x509.Certificate {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := parseCertificate(contents)
	if err != nil {
		t.Fatal(err)
	}
	return certificate
}

func readNames(t *testing.T, directory string) []string {
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

func TestGatewayMaterialRejectsTamperedTunnelCASignature(t *testing.T) {
	installationID := strings.Repeat("e", 64)
	root := filepath.Join(t.TempDir(), "gateway")
	material, err := EnsureGatewayMaterial(root, installationID)
	if err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(material.CACertFile)
	if err != nil {
		t.Fatal(err)
	}
	block, rest := pem.Decode(contents)
	if block == nil || len(rest) != 0 || len(block.Bytes) == 0 {
		t.Fatal("tunnel CA could not be decoded")
	}
	block.Bytes[len(block.Bytes)-1] ^= 0x01
	if err := os.WriteFile(material.CACertFile, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureGatewayMaterial(root, installationID); err == nil {
		t.Fatal("tunnel CA with a tampered self-signature was accepted")
	}
}

// The tunnel agent's material travels in the handover bundle, in its own
// directory, so nothing of the tunnel sits in the gateway's own state.
func TestTunnelMaterialLivesInTheHandoverBundle(t *testing.T) {
	installationID := strings.Repeat("a1", 32)
	root := filepath.Join(t.TempDir(), "gateway")
	material, err := EnsureGatewayMaterial(root, installationID)
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(t.TempDir(), "bundle")
	delivered, err := EnsureTunnelMaterial(bundle, material)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"frps-token", "tunnel-client.crt.pem", "tunnel-client.key.pem"}
	entries, err := os.ReadDir(delivered.Directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(want) {
		t.Fatalf("tunnel material holds %d entries, want %v", len(entries), want)
	}
	for index, name := range want {
		if entries[index].Name() != name {
			t.Fatalf("tunnel material entry %d is %q, want %q", index, entries[index].Name(), name)
		}
	}
	// The gateway keeps what the tunnel server and the 443 entrance on its own
	// machine read, and never the client identity.
	server := readNames(t, root)
	sort.Strings(server)
	wantServer := []string{"frps-token", "tunnel-ca.crt.pem", "tunnel-ca.key.pem"}
	if len(server) != len(wantServer) {
		t.Fatalf("gateway state root holds %v, want %v", server, wantServer)
	}
	for index, name := range wantServer {
		if server[index] != name {
			t.Fatalf("gateway state root holds %v, want %v", server, wantServer)
		}
	}
}

// A tunnel agent that is running authenticates with the files it was started
// with, so ensuring material may issue an identity but never replace one.
// Renewal is the explicit way to replace it, and it keeps the tunnel CA.
func TestTunnelClientIdentityIsKeptUntilRenewed(t *testing.T) {
	installationID := strings.Repeat("a1", 32)
	root := filepath.Join(t.TempDir(), "gateway")
	material, err := EnsureGatewayMaterial(root, installationID)
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(t.TempDir(), "bundle")
	issued, err := EnsureTunnelMaterial(bundle, material)
	if err != nil {
		t.Fatal(err)
	}
	if !validTunnelClient(readCertificate(t, issued.CertificateFile), material, time.Now()) {
		t.Fatal("issued certificate is not a valid client identity for the tunnel CA")
	}
	again, err := EnsureTunnelMaterial(bundle, material)
	if err != nil {
		t.Fatal(err)
	}
	if again.Fingerprint != issued.Fingerprint {
		t.Fatalf("ensure replaced an existing tunnel identity: %s -> %s", issued.Fingerprint, again.Fingerprint)
	}
	renewed, err := RenewTunnelMaterial(bundle, material)
	if err != nil {
		t.Fatal(err)
	}
	if renewed.Fingerprint == issued.Fingerprint {
		t.Fatal("renewal did not replace the tunnel client identity")
	}
	renewedCertificate := readCertificate(t, renewed.CertificateFile)
	if !validTunnelClient(renewedCertificate, material, time.Now()) {
		t.Fatal("renewed certificate is not a valid client identity for the tunnel CA")
	}
	if previous := readCertificate(t, issued.CertificateFile); !bytes.Equal(previous.RawIssuer, renewedCertificate.RawIssuer) {
		t.Fatal("renewal did not keep the tunnel CA")
	}
}

func TestTunnelMaterialRefusesKeyThatDoesNotMatchCertificate(t *testing.T) {
	root := filepath.Join(t.TempDir(), "gateway")
	material, err := EnsureGatewayMaterial(root, strings.Repeat("a1", 32))
	if err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(t.TempDir(), "bundle")
	delivered, err := EnsureTunnelMaterial(bundle, material)
	if err != nil {
		t.Fatal(err)
	}
	otherKey, err := os.ReadFile(material.CAKeyFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(delivered.KeyFile, otherKey, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := EnsureTunnelMaterial(bundle, material); err == nil {
		t.Fatal("a client key that does not match the certificate was accepted")
	}
}
