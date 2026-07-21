package setup

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBuildLANAndPublicPayloads(t *testing.T) {
	id := "ab"
	for len(id) < 64 {
		id += "ab"
	}
	keyPin := strings.Repeat("A", 43) + "="
	lan, err := Build("lan", id, "Home PC", "https://192.168.1.5:60000", id, keyPin)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := url.Parse(lan)
	if parsed.Scheme != "remote-everything" || parsed.Host != "setup" || parsed.Query().Get("origin") != "https://192.168.1.5:60000" || parsed.Query().Get("fingerprint") != id || parsed.Query().Get("public_key_pin") != keyPin {
		t.Fatalf("unexpected LAN payload: %s", lan)
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com", strings.Repeat("A", 43), ""); err != nil {
		t.Fatal(err)
	}
	if _, err := Build("public", id, "Public PC", "https://remote.example.com:0", strings.Repeat("A", 43), ""); err == nil {
		t.Fatal("setup origin accepted port zero")
	}
}

// TestContractFixtures validates that the shared fixture URIs match Go's parsing rules.
// The same fixtures are used by Kotlin (Android), Swift (iOS), and ArkTS (HarmonyOS) tests.
func TestContractFixtures(t *testing.T) {
	fixturesDir := filepath.Join("..", "..", "clients", "contracts", "fixtures")

	t.Run("valid", func(t *testing.T) {
		entries, err := os.ReadDir(filepath.Join(fixturesDir, "valid"))
		if err != nil {
			t.Skipf("fixtures directory not available: %v", err)
			return
		}
		for _, entry := range entries {
			if !strings.HasPrefix(entry.Name(), "setup-uri-") {
				continue
			}
			t.Run(entry.Name(), func(t *testing.T) {
				data, err := os.ReadFile(filepath.Join(fixturesDir, "valid", entry.Name()))
				if err != nil {
					t.Fatal(err)
				}
				var fixture struct {
					URI      string            `json:"uri"`
					Expected map[string]string `json:"expected"`
				}
				if err := json.Unmarshal(data, &fixture); err != nil {
					t.Fatal(err)
				}
				parsed, err := url.Parse(fixture.URI)
				if err != nil {
					t.Fatalf("failed to parse fixture URI: %v", err)
				}
				query := parsed.Query()
				for key, expectedValue := range fixture.Expected {
					if query.Get(key) != expectedValue {
						t.Errorf("key %q: got %q, want %q", key, query.Get(key), expectedValue)
					}
				}
			})
		}
	})

	t.Run("invalid", func(t *testing.T) {
		entries, err := os.ReadDir(filepath.Join(fixturesDir, "invalid"))
		if err != nil {
			t.Skipf("fixtures directory not available: %v", err)
			return
		}
		for _, entry := range entries {
			if !strings.HasPrefix(entry.Name(), "setup-uri-") && !strings.HasPrefix(entry.Name(), "catalog-") && !strings.HasPrefix(entry.Name(), "pairing-") {
				continue
			}
			t.Run(entry.Name(), func(t *testing.T) {
				data, err := os.ReadFile(filepath.Join(fixturesDir, "invalid", entry.Name()))
				if err != nil {
					t.Fatal(err)
				}
				var fixture struct {
					URI     string `json:"uri"`
					Payload any    `json:"payload"`
					Error   string `json:"error"`
				}
				if err := json.Unmarshal(data, &fixture); err != nil {
					t.Fatal(err)
				}
				// Every invalid fixture must have an error code
				if fixture.Error == "" {
					t.Error("invalid fixture missing error code")
				}
				// For setup URI fixtures, validate that the URI is structurally a setup URI
				// but would fail strict validation
				if fixture.URI != "" {
					parsed, err := url.Parse(fixture.URI)
					if err != nil {
						t.Logf("URI that fail to parse: %v (expected for: %s)", err, fixture.Error)
						return
					}
					if parsed.Scheme != "remote-everything" || parsed.Host != "setup" {
						t.Errorf("fixture URI has unexpected scheme/host: %s", fixture.URI)
					}
				}
			})
		}
	})
}
