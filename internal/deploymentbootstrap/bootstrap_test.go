package deploymentbootstrap

import (
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGatewayMaterialAndNodeBundleRoundTrip(t *testing.T) {
	installationID := strings.Repeat("a", 64)
	controlToken := strings.Repeat("b", 64)
	material, err := EnsureGatewayMaterial(filepath.Join(t.TempDir(), "gateway"), installationID, controlToken)
	if err != nil {
		t.Fatal(err)
	}
	bundleRoot := filepath.Join(t.TempDir(), "bundle")
	if err := WriteNodeBundle(bundleRoot, material); err != nil {
		t.Fatal(err)
	}
	bundle, err := ReadNodeBundle(bundleRoot)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.InstallationID != installationID || bundle.ControlToken != controlToken || bundle.FRPSToken != material.FRPSToken {
		t.Fatalf("bundle identity or token mismatch: %+v", bundle)
	}
	if err := WriteNodeBundle(bundleRoot, material); err != nil {
		t.Fatalf("bundle creation is not idempotent: %v", err)
	}
}

func TestGatewayMaterialRejectsTamperedTunnelCASignature(t *testing.T) {
	installationID := strings.Repeat("e", 64)
	controlToken := strings.Repeat("f", 64)
	root := filepath.Join(t.TempDir(), "gateway")
	material, err := EnsureGatewayMaterial(root, installationID, controlToken)
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
	if _, err := EnsureGatewayMaterial(root, installationID, controlToken); err == nil {
		t.Fatal("tunnel CA with a tampered self-signature was accepted")
	}
}

func TestNodeBundleRejectsUnknownManifestFieldsAndDifferentCA(t *testing.T) {
	installationID := strings.Repeat("c", 64)
	controlToken := strings.Repeat("d", 64)
	first, err := EnsureGatewayMaterial(filepath.Join(t.TempDir(), "first"), installationID, controlToken)
	if err != nil {
		t.Fatal(err)
	}
	bundleRoot := filepath.Join(t.TempDir(), "bundle")
	if err := WriteNodeBundle(bundleRoot, first); err != nil {
		t.Fatal(err)
	}
	second, err := EnsureGatewayMaterial(filepath.Join(t.TempDir(), "second"), installationID, controlToken)
	if err != nil {
		t.Fatal(err)
	}
	second.FRPSToken = first.FRPSToken
	if err := WriteNodeBundle(bundleRoot, second); err == nil {
		t.Fatal("existing bundle signed by another tunnel CA was accepted")
	}
	manifestPath := filepath.Join(bundleRoot, ManifestName)
	contents, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	contents = []byte(strings.Replace(string(contents), "\n", ",\"unknown\":true}\n", 1))
	contents = []byte(strings.Replace(string(contents), "},\"unknown\"", ",\"unknown\"", 1))
	if err := os.WriteFile(manifestPath, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadNodeBundle(bundleRoot); err == nil {
		t.Fatal("unknown bootstrap manifest field was accepted")
	}
}
