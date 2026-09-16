package gatewaycore

import (
	"os"
	"strings"
	"testing"
)

// A gateway that is already bound must keep the token its node accepted:
// running the entrance's init again may not mint a new one.
func TestEnsureControlTokenCreatesOnceAndKeepsTheToken(t *testing.T) {
	root := t.TempDir()
	first, err := EnsureControlToken(root)
	if err != nil {
		t.Fatal(err)
	}
	if !validToken.MatchString(first) {
		t.Fatalf("generated token %q is not a 64-hex secret", first)
	}
	second, err := EnsureControlToken(root)
	if err != nil {
		t.Fatal(err)
	}
	if second != first {
		t.Fatalf("ensure replaced the control token: %s -> %s", first, second)
	}
	if read, err := ReadControlToken(root); err != nil || read != first {
		t.Fatalf("ReadControlToken = %q, %v", read, err)
	}
}

func TestReadControlTokenRejectsAMalformedToken(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(ControlTokenPath(root), []byte("not-a-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadControlToken(root); err == nil {
		t.Fatal("a malformed control token was accepted")
	}
	if _, err := EnsureControlToken(root); err == nil {
		t.Fatal("ensure overwrote a malformed control token instead of reporting it")
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
