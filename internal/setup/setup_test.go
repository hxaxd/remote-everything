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
	lan, err := Build("lan", id, "Home PC", "https://192.168.1.5:60000", invitation, id, keyPin)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := url.Parse(lan)
	if parsed.Scheme != "remote-everything" || parsed.Host != "setup" || parsed.Query().Get("origin") != "https://192.168.1.5:60000" || parsed.Query().Get("fingerprint") != id || parsed.Query().Get("public_key_pin") != keyPin || parsed.Query().Get("invitation") != invitation {
		t.Fatalf("unexpected LAN payload: %s", lan)
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com", invitation, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com:0", invitation, "", ""); err == nil {
		t.Fatal("setup origin accepted port zero")
	}
	// A LAN entrance pins the certificate it serves itself, and both modes are
	// admitted by an invitation rather than by an entrance-wide secret.
	if _, err := Build("lan", id, "Home PC", "https://192.168.1.5:60000", invitation, id, ""); err == nil {
		t.Fatal("LAN setup accepted a missing certificate pin")
	}
	if _, err := Build("lan", id, "Home PC", "https://192.168.1.5:60000", "", id, keyPin); err == nil {
		t.Fatal("LAN setup accepted a missing invitation")
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com", invitation, id, keyPin); err == nil {
		t.Fatal("public setup accepted pins for an entrance it does not have")
	}
}
