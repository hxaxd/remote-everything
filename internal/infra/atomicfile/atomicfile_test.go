package atomicfile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteCreatesParentsAndReplacesContents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "state.json")
	if err := Write(path, []byte("first\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Write(path, []byte("second\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "second\n" {
		t.Fatalf("contents = %q", contents)
	}
	matches, err := filepath.Glob(filepath.Join(filepath.Dir(path), "state.json.*.tmp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("temporary files remain after replacement: %v", matches)
	}
}

func TestWriteCleansTemporaryFileWhenReplacementFails(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "state")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := Write(target, []byte("value"), 0o600); err == nil {
		t.Fatal("replacing a directory unexpectedly succeeded")
	}
	matches, err := filepath.Glob(filepath.Join(root, "state.*.tmp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("temporary files remain after failed replacement: %v", matches)
	}
}
