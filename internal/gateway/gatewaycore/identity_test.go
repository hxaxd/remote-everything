package gatewaycore

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A gateway that is already bound must keep the token its node accepted: adding
// that node again may not mint a new one.
func TestEnsureNodeTokenCreatesOnceAndKeepsTheToken(t *testing.T) {
	root := t.TempDir()
	nodeID := strings.Repeat("a1", 32)
	first, err := EnsureNodeToken(root, nodeID)
	if err != nil {
		t.Fatal(err)
	}
	if !validToken.MatchString(first) {
		t.Fatalf("generated token %q is not a 64-hex secret", first)
	}
	second, err := EnsureNodeToken(root, nodeID)
	if err != nil {
		t.Fatal(err)
	}
	if second != first {
		t.Fatalf("ensure replaced the control token: %s -> %s", first, second)
	}
	if read, err := ReadNodeToken(root, nodeID); err != nil || read != first {
		t.Fatalf("ReadNodeToken = %q, %v", read, err)
	}
	// One token per node: what one of them was given says nothing about another.
	other, err := EnsureNodeToken(root, strings.Repeat("b2", 32))
	if err != nil || other == first {
		t.Fatalf("the second node got %q, %v", other, err)
	}
	if _, err := ReadNodeToken(root, strings.Repeat("c3", 32)); err == nil {
		t.Fatal("a node that was never given a token had one")
	}
}

func TestReadNodeTokenRejectsAMalformedToken(t *testing.T) {
	root := t.TempDir()
	nodeID := strings.Repeat("a1", 32)
	if err := os.MkdirAll(filepath.Dir(NodeTokenPath(root, nodeID)), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(NodeTokenPath(root, nodeID), []byte("not-a-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadNodeToken(root, nodeID); err == nil {
		t.Fatal("a malformed control token was accepted")
	}
	if _, err := EnsureNodeToken(root, nodeID); err == nil {
		t.Fatal("ensure overwrote a malformed control token instead of reporting it")
	}
	// A node id is part of the path its token is kept at, so one that is not an id
	// is refused rather than followed.
	if _, err := ReadNodeToken(root, "../control-token"); err == nil {
		t.Fatal("a path was accepted as a node id")
	}
}

func TestIdentityBundleCarriesTheBoundIdentity(t *testing.T) {
	directory := t.TempDir()
	identity := Identity{InstallationID: strings.Repeat("a", 64), ControlToken: strings.Repeat("b", 64)}
	if err := identity.WriteBundle(directory); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(directory + string(os.PathSeparator) + "bootstrap.json")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(contents), identity.InstallationID) {
		t.Fatalf("bundle does not carry the installation id: %s", contents)
	}
}
