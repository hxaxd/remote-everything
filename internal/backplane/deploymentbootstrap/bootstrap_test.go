package deploymentbootstrap

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestNodeBundle(t *testing.T, installationID, controlToken string) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "bundle")
	if err := WriteNodeBundle(root, installationID, controlToken); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestNodeBundleCarriesIdentityOnly(t *testing.T) {
	installationID := strings.Repeat("a", 64)
	controlToken := strings.Repeat("b", 64)
	root := writeTestNodeBundle(t, installationID, controlToken)
	bundle, err := ReadNodeBundle(root)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.InstallationID != installationID || bundle.ControlToken != controlToken {
		t.Fatalf("bundle identity mismatch: %+v", bundle)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("node bundle holds %d entries, want the identity and nothing else", len(entries))
	}
	for _, entry := range entries {
		if entry.Name() != ManifestName && entry.Name() != ControlTokenName {
			t.Fatalf("node bundle carries %q, but a node bundle holds only its identity", entry.Name())
		}
	}
	if err := WriteNodeBundle(root, installationID, controlToken); err != nil {
		t.Fatalf("rewriting the same identity is not idempotent: %v", err)
	}
	if err := WriteNodeBundle(root, strings.Repeat("c", 64), controlToken); err == nil {
		t.Fatal("a bundle holding another identity was overwritten")
	}
}

// A control token is replaced when the machine that held it is taken out of reach
// again, and the replacement is delivered over the bundle that machine already has:
// nothing else can tell it the token it authenticates with changed.
func TestReplaceNodeBundleOverwritesTheIdentityItCarries(t *testing.T) {
	installationID := strings.Repeat("a", 64)
	root := writeTestNodeBundle(t, installationID, strings.Repeat("b", 64))
	replacement := strings.Repeat("d", 64)
	if err := ReplaceNodeBundle(root, installationID, replacement); err != nil {
		t.Fatal(err)
	}
	bundle, err := ReadNodeBundle(root)
	if err != nil {
		t.Fatal(err)
	}
	if bundle.ControlToken != replacement || bundle.InstallationID != installationID {
		t.Fatalf("the replacement did not arrive: %+v", bundle)
	}
	if entries, err := os.ReadDir(root); err != nil || len(entries) != 2 {
		t.Fatalf("replacing left %v, %v", entries, err)
	}
}

func TestNodeBundleRejectsUnknownManifestFields(t *testing.T) {
	root := writeTestNodeBundle(t, strings.Repeat("c", 64), strings.Repeat("d", 64))
	manifestPath := filepath.Join(root, ManifestName)
	contents, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	tampered := strings.Replace(string(contents), "}", ",\"unknown\":true}", 1)
	if err := os.WriteFile(manifestPath, []byte(tampered), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadNodeBundle(root); err == nil {
		t.Fatal("unknown bootstrap manifest field was accepted")
	}
}
