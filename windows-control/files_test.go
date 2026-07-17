package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func setupFiles(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	filesRoot = root
	t.Cleanup(func() { filesRoot = os.Getenv("USERPROFILE") })
	if err := os.MkdirAll(filepath.Join(root, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "docs", "a.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "b.bin"), []byte{0, 1, 2}, 0o600); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestResolveFilePath(t *testing.T) {
	root := setupFiles(t)
	if got, err := resolveFilePath("/docs"); err != nil || got != filepath.Join(root, "docs") {
		t.Fatalf("resolve /docs: %v %v", got, err)
	}
	if got, err := resolveFilePath("/"); err != nil || got != root {
		t.Fatalf("resolve /: %v %v", got, err)
	}
	// 构造上不可能逃逸：/../ 被 Clean 压回根内，目标不存在则报错
	if _, err := resolveFilePath("/../../etc/passwd"); err == nil {
		t.Fatal("expected error for traversal-shaped path")
	}
	if _, err := resolveFilePath("/missing"); err == nil {
		t.Fatal("expected error for missing path")
	}
}

func TestFilesList(t *testing.T) {
	setupFiles(t)
	recorder := httptest.NewRecorder()
	filesListHandler(recorder, httptest.NewRequest(http.MethodGet, "/api/list?path=/docs", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("list: %d %s", recorder.Code, recorder.Body.String())
	}
	var result struct {
		OK      bool        `json:"ok"`
		Path    string      `json:"path"`
		Entries []fileEntry `json:"entries"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil || !result.OK || result.Path != "/docs" {
		t.Fatalf("bad list response: %s", recorder.Body.String())
	}
	if len(result.Entries) != 1 || result.Entries[0].Name != "a.txt" || result.Entries[0].Dir || result.Entries[0].Size != 5 {
		t.Fatalf("unexpected entries: %+v", result.Entries)
	}
}

func TestFilesGet(t *testing.T) {
	setupFiles(t)
	recorder := httptest.NewRecorder()
	filesGetHandler(recorder, httptest.NewRequest(http.MethodGet, "/api/file?path=/docs/a.txt", nil))
	if recorder.Code != http.StatusOK || recorder.Body.String() != "hello" {
		t.Fatalf("get: %d %q", recorder.Code, recorder.Body.String())
	}
	download := httptest.NewRecorder()
	filesGetHandler(download, httptest.NewRequest(http.MethodGet, "/api/file?path=/docs/a.txt&download=1", nil))
	if download.Header().Get("Content-Disposition") == "" {
		t.Fatal("download should set Content-Disposition")
	}
	dir := httptest.NewRecorder()
	filesGetHandler(dir, httptest.NewRequest(http.MethodGet, "/api/file?path=/docs", nil))
	if dir.Code != http.StatusNotFound {
		t.Fatalf("dir should be 404: %d", dir.Code)
	}
}

func TestFilesUpload(t *testing.T) {
	root := setupFiles(t)
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	part, err := writer.CreateFormFile("file", "c.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := part.Write([]byte("xyz")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/upload?path=/docs", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	recorder := httptest.NewRecorder()
	filesUploadHandler(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("upload: %d %s", recorder.Code, recorder.Body.String())
	}
	contents, err := os.ReadFile(filepath.Join(root, "docs", "c.txt"))
	if err != nil || string(contents) != "xyz" {
		t.Fatalf("uploaded file wrong: %v %q", err, contents)
	}
}
