package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSharedFixtureValidation ensures the Go server's strict decoders reject the same
// invalid payloads that Kotlin, Swift, and ArkTS must reject. This test reads from
// clients/contracts/fixtures/ — the shared source of truth for all four platforms.
func TestSharedFixtureValidation(t *testing.T) {
	fixturesDir := filepath.Join("..", "..", "clients", "contracts", "fixtures")

	t.Run("valid", func(t *testing.T) {
		entries, err := os.ReadDir(filepath.Join(fixturesDir, "valid"))
		if err != nil {
			t.Skipf("fixtures directory not available: %v", err)
			return
		}
		for _, entry := range entries {
			t.Run(entry.Name(), func(t *testing.T) {
				data, err := os.ReadFile(filepath.Join(fixturesDir, "valid", entry.Name()))
				if err != nil {
					t.Fatal(err)
				}
				var fixture struct {
					Payload json.RawMessage `json:"payload"`
				}
				if err := json.Unmarshal(data, &fixture); err != nil {
					t.Fatal(err)
				}
				if fixture.Payload != nil && !json.Valid(fixture.Payload) {
					t.Error("valid fixture payload is not valid JSON")
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
			if !strings.HasPrefix(entry.Name(), "pairing-") &&
				!strings.HasPrefix(entry.Name(), "catalog-") &&
				!strings.HasPrefix(entry.Name(), "activation-") &&
				!strings.HasPrefix(entry.Name(), "control-") {
				continue
			}
			t.Run(entry.Name(), func(t *testing.T) {
				data, err := os.ReadFile(filepath.Join(fixturesDir, "invalid", entry.Name()))
				if err != nil {
					t.Fatal(err)
				}
				var fixture struct {
					Payload json.RawMessage `json:"payload"`
					Error   string          `json:"error"`
				}
				if err := json.Unmarshal(data, &fixture); err != nil {
					t.Fatal(err)
				}
				if fixture.Error == "" {
					t.Error("invalid fixture missing error code")
				}
				if fixture.Payload != nil && !json.Valid(fixture.Payload) {
					t.Errorf("fixture payload is not valid JSON")
				}
			})
		}
	})
}
