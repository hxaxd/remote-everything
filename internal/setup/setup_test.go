package setup

import (
	"net/url"
	"slices"
	"strings"
	"testing"
)

func TestBuildCarriesTheNodeTheInvitationOpens(t *testing.T) {
	nodeID := strings.Repeat("ab", 32)
	keyPin := strings.Repeat("A", 43) + "="
	invitation := strings.Repeat("B", 43)
	pinned, err := Build(nodeID, "Home PC", "https://192.168.1.5:60000", invitation, nodeID, keyPin)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := url.Parse(pinned)
	if parsed.Scheme != "remote-everything" || parsed.Host != "setup" {
		t.Fatalf("unexpected payload: %s", pinned)
	}
	carried := parsed.Query()
	if carried.Get("node") != nodeID || carried.Get("node_name") != "Home PC" || carried.Get("origin") != "https://192.168.1.5:60000" ||
		carried.Get("fingerprint") != nodeID || carried.Get("public_key_pin") != keyPin || carried.Get("invitation") != invitation {
		t.Fatalf("unexpected pinned payload: %s", pinned)
	}
	// What an invitation carries is what a client needs to redeem it: the node it
	// opens, what that node is called, where the gateway is, and the invitation
	// itself. There is no version and no shape on the wire — a client reads what it
	// was given rather than a name for it.
	plain, err := Build(nodeID, "Public PC", "https://remote.example.com", invitation, "", "")
	if err != nil {
		t.Fatal(err)
	}
	plainQuery, _ := url.Parse(plain)
	keys := make([]string, 0, len(plainQuery.Query()))
	for key := range plainQuery.Query() {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	if strings.Join(keys, ",") != "invitation,node,node_name,origin" {
		t.Fatalf("an invitation carries %v", keys)
	}
	if _, err := Build(nodeID, "Public PC", "https://remote.example.com:0", invitation, "", ""); err == nil {
		t.Fatal("setup origin accepted port zero")
	}
	// A gateway that serves a certificate of its own states both halves of the pin
	// or neither, and the invitation is what every URI carries.
	if _, err := Build(nodeID, "Home PC", "https://192.168.1.5:60000", invitation, nodeID, ""); err == nil {
		t.Fatal("setup accepted half a certificate pin")
	}
	if _, err := Build(nodeID, "Home PC", "https://192.168.1.5:60000", "", nodeID, keyPin); err == nil {
		t.Fatal("setup accepted a missing invitation")
	}
	// A name is carried the way the state records it, so a name an operator padded
	// is the same name either way.
	if padded, err := Build(nodeID, "  Home PC  ", "https://192.168.1.5:60000", invitation, "", ""); err != nil {
		t.Fatal(err)
	} else if parsed, _ := url.Parse(padded); parsed.Query().Get("node_name") != "Home PC" {
		t.Fatalf("a padded name was carried as %q", parsed.Query().Get("node_name"))
	}
	// The node is named by its id and by the label its operator gave it: an
	// invitation that says neither, or says something that is not an id, opens
	// nothing a client can ask for.
	for name, build := range map[string]func() error{
		"no node id": func() error {
			_, err := Build("", "Home PC", "https://192.168.1.5:60000", invitation, "", "")
			return err
		},
		"short node id": func() error {
			_, err := Build("Home", "Home PC", "https://192.168.1.5:60000", invitation, "", "")
			return err
		},
		"no node name": func() error { _, err := Build(nodeID, "", "https://192.168.1.5:60000", invitation, "", ""); return err },
		"blank node name": func() error {
			_, err := Build(nodeID, "   ", "https://192.168.1.5:60000", invitation, "", "")
			return err
		},
	} {
		if err := build(); err == nil {
			t.Fatalf("setup accepted %s", name)
		}
	}
}
