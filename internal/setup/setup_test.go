package setup

import (
	"net/url"
	"strings"
	"testing"
)

func TestBuildLANAndPublicPayloads(t *testing.T) {
	id := "ab"
	for len(id) < 64 {
		id += "ab"
	}
	keyPin := strings.Repeat("A", 43) + "="
	invitation := strings.Repeat("B", 43)
	lan, err := Build(id, "Home PC", "https://192.168.1.5:60000", invitation, id, keyPin)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := url.Parse(lan)
	if parsed.Scheme != "remote-everything" || parsed.Host != "setup" || parsed.Query().Get("origin") != "https://192.168.1.5:60000" || parsed.Query().Get("fingerprint") != id || parsed.Query().Get("public_key_pin") != keyPin || parsed.Query().Get("invitation") != invitation {
		t.Fatalf("unexpected LAN payload: %s", lan)
	}
	plain, err := Build(id, "Public PC", "https://remote.example.com", invitation, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if parsed, _ := url.Parse(plain); parsed.Query().Get("mode") != "public" || parsed.Query().Get("fingerprint") != "" {
		t.Fatalf("an entrance with no certificate of its own named itself otherwise: %s", plain)
	}
	if _, err := Build(id, "Public PC", "https://remote.example.com:0", invitation, "", ""); err == nil {
		t.Fatal("setup origin accepted port zero")
	}
	// An entrance that serves a certificate of its own states both halves of the
	// pin or neither, and the invitation is what every URI carries.
	if _, err := Build(id, "Home PC", "https://192.168.1.5:60000", invitation, id, ""); err == nil {
		t.Fatal("setup accepted half a certificate pin")
	}
	if _, err := Build(id, "Home PC", "https://192.168.1.5:60000", "", id, keyPin); err == nil {
		t.Fatal("setup accepted a missing invitation")
	}
}
