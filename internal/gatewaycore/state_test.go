package gatewaycore

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/netaddr"
)

func testListeners(t *testing.T) []Listener {
	t.Helper()
	listeners, err := AllocateListeners(testPreferences())
	if err != nil {
		t.Fatal(err)
	}
	return listeners
}

func testPreferences() []ListenerPreference {
	return []ListenerPreference{
		{Name: "status", Host: "127.0.0.1", PreferredPort: 58629},
		{Name: "pairing", Host: "127.0.0.1", PreferredPort: 58631},
		{Name: "node_tunnel", Host: "127.0.0.1", PreferredPort: 58628},
	}
}

// Every gateway records the same thing about itself: the identity a node binds
// it by, the origin its clients dial, and the listeners it serves, each named.
func TestStateRoundTripKeepsIdentityAndNamedListeners(t *testing.T) {
	installationID := strings.Repeat("a1", 32)
	state, err := NewState(installationID, "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "gateway.json")
	if err := state.Save(path); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.InstallationID != installationID || loaded.Origin != "https://gateway.example" || len(loaded.Listeners) != len(state.Listeners) {
		t.Fatalf("round trip changed the state: %+v", loaded)
	}
	for _, preference := range testPreferences() {
		address, err := loaded.Address(preference.Name)
		if err != nil || !netaddr.ValidListen(address) {
			t.Fatalf("listener %s = %q, %v", preference.Name, address, err)
		}
	}
	if _, err := loaded.Address("missing"); err == nil {
		t.Fatal("an unknown listener name was answered")
	}
}

func TestLoadStateRejectsStatesNothingCanServe(t *testing.T) {
	installationID := strings.Repeat("a1", 32)
	id := `"installation_id":"` + installationID + `"`
	origin := `"origin":"https://gateway.example"`
	valid := `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`
	for name, contents := range map[string]string{
		"unknown field":     `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"}],"extra":true}`,
		"no listeners":      `{"schema":1,` + id + `,` + origin + `,"listeners":[]}`,
		"duplicate name":    `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"},{"name":"lan","address":"0.0.0.0:58627"}]}`,
		"duplicate address": `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"},{"name":"lan2","address":"0.0.0.0:58626"}]}`,
		"hostname":          `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"node.example:58626"}]}`,
		"privileged port":   `{"schema":1,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:80"}]}`,
		"other schema":      `{"schema":2,` + id + `,` + origin + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`,
		// The origin is what clients dial, so it is part of what a gateway is.
		"no origin":    `{"schema":1,` + id + `,"listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`,
		"plain origin": `{"schema":1,` + id + `,"origin":"http://gateway.example","listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`,
		"origin path":  `{"schema":1,` + id + `,"origin":"https://gateway.example/apps","listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`,
		"origin query": `{"schema":1,` + id + `,"origin":"https://gateway.example?next=evil","listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`,
		"origin user":  `{"schema":1,` + id + `,"origin":"https://user@gateway.example","listeners":[{"name":"lan","address":"0.0.0.0:58626"}]}`,
	} {
		path := filepath.Join(t.TempDir(), "gateway.json")
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadState(path); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
	path := filepath.Join(t.TempDir(), "gateway.json")
	if err := os.WriteFile(path, []byte(valid), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadState(path); err != nil {
		t.Fatalf("a wildcard listener was rejected: %v", err)
	}
}

// Repair moves the ports and nothing else: a listener's name and host are what
// the rest of the deployment was pointed at.
func TestRepairKeepsNamesAndHosts(t *testing.T) {
	state, err := NewState(strings.Repeat("a1", 32), "https://gateway.example", testListeners(t))
	if err != nil {
		t.Fatal(err)
	}
	repaired, err := state.Repair(map[string]int{"status": 58629, "pairing": 58631, "node_tunnel": 58628})
	if err != nil {
		t.Fatal(err)
	}
	if repaired.InstallationID != state.InstallationID || repaired.Schema != state.Schema || repaired.Origin != state.Origin {
		t.Fatalf("repair changed the identity: %+v", repaired)
	}
	before := map[string]string{}
	for _, listener := range state.Listeners {
		before[listener.Name] = listener.Address
	}
	for _, listener := range repaired.Listeners {
		host, _, err := net.SplitHostPort(listener.Address)
		if err != nil || host != netaddrHost(before[listener.Name]) || !netaddr.ValidListen(listener.Address) {
			t.Fatalf("repair changed host or validity of %s: %q", listener.Name, listener.Address)
		}
	}
}

func netaddrHost(address string) string {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return ""
	}
	return host
}
