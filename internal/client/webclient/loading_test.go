package webclient

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/backplane/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/client/webloading"
)

// Exercise the authenticated response path in a real browser, with delayed application content.
func TestBrowserLoading(t *testing.T) {
	if os.Getenv("PLAYWRIGHT_MODULE") == "" {
		t.Skip("PLAYWRIGHT_MODULE not configured")
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get(webloading.ThemeHeader) != "" || r.Header.Get(SessionHeaderName) != "" {
			t.Error("internal header reached application")
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'")
		fmt.Fprint(w, `<!doctype html><html><head><title>Application</title></head><body><div id="root"></div></body></html>`)
	}))
	defer upstream.Close()
	target, _ := url.Parse(upstream.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	director := proxy.Director
	proxy.Director = func(r *http.Request) {
		director(r)
		proxysecurity.StripInternalHeaders(r.Header)
		webloading.Prepare(r)
	}
	proxy.ModifyResponse = webloading.Apply
	manager, _ := NewSessionManager(t.TempDir())
	credential, err := manager.Pair(strings.Repeat("a", 64), "Browser", DefaultSessionTTL)
	if err != nil {
		t.Fatal(err)
	}
	handler, _ := NewHandler(nil, manager)
	gateway := httptest.NewServer(handler.WithWebSession(proxy))
	defer gateway.Close()
	node := os.Getenv("NODE_BINARY")
	if node == "" {
		node = "node"
	}
	command := exec.Command(node, "tests/loading.cjs")
	command.Env = append(os.Environ(), "LOADING_TEST_ORIGIN="+gateway.URL, "LOADING_TEST_TOKEN="+credential.Token)
	if result, err := command.CombinedOutput(); err != nil {
		t.Fatalf("browser loading: %v\n%s", err, result)
	} else {
		t.Log(string(result))
	}
}
