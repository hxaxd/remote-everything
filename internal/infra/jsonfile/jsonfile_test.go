package jsonfile

import (
	"os"
	"path/filepath"
	"testing"
)

type sample struct {
	Schema int    `json:"schema"`
	Name   string `json:"name"`
}

func TestRoundTripRejectsUnknownFieldsAndTrailingContent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := Write(path, sample{Schema: 1, Name: "first"}, 0o600); err != nil {
		t.Fatal(err)
	}
	var loaded sample
	if err := Read(path, &loaded); err != nil {
		t.Fatal(err)
	}
	if loaded.Schema != 1 || loaded.Name != "first" {
		t.Fatalf("loaded %+v", loaded)
	}
	for name, contents := range map[string]string{
		"unknown field":    `{"schema":1,"name":"first","extra":true}`,
		"trailing content": `{"schema":1,"name":"first"} {"schema":2}`,
	} {
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := Read(path, &loaded); err == nil {
			t.Fatalf("%s was accepted", name)
		}
	}
	if err := Read(filepath.Join(t.TempDir(), "missing.json"), &loaded); !os.IsNotExist(err) {
		t.Fatalf("reading a missing file returned %v", err)
	}
}
