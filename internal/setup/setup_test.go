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
	lan, err := Build("lan", id, "Home PC", "https://192.168.1.5:60000", id, keyPin, id)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := url.Parse(lan)
	if parsed.Scheme != "remote-everything" || parsed.Host != "setup" || parsed.Query().Get("origin") != "https://192.168.1.5:60000" || parsed.Query().Get("fingerprint") != id || parsed.Query().Get("public_key_pin") != keyPin || parsed.Query().Get("token") != id {
		t.Fatalf("unexpected LAN payload: %s", lan)
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com", strings.Repeat("A", 43), "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com:0", strings.Repeat("A", 43), "", ""); err == nil {
		t.Fatal("setup origin accepted port zero")
	}
	if _, err := Build("lan", id, "Home PC", "https://192.168.1.5:60000", id, keyPin, ""); err == nil {
		t.Fatal("LAN setup accepted empty token")
	}
}
