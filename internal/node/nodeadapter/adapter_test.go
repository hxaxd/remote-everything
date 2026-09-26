package nodeadapter

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func testLog(format string, args ...any) {}

func TestAdapterEmptySourceUnavailable(t *testing.T) {
	a := New("", testLog)
	if !a.Unavailable() {
		t.Fatal("empty source should be unavailable")
	}
	// hooks should be no-ops, not panics
	a.OnStart(nil, 8080, "test")
	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/", nil)
	a.OnRequest(req, "test")
	a.OnStop("test")
}

func TestAdapterSyntaxErrorUnavailable(t *testing.T) {
	a := New("function(){", testLog)
	if !a.Unavailable() {
		t.Fatal("syntax error should be unavailable")
	}
	a.OnStart(nil, 8080, "test")
}

// The contract of the optional adapter layer: defined hooks take effect, absent
// hooks are skipped silently. Asserted through the effects each hook has on the
// request, response and shared state rather than through the resolved callables.
func TestAdapterHookEffectsAndAbsentHooks(t *testing.T) {
	full := `
function onStart() { __state.set("token", "abc"); }
function onRequest() { __req.setQuery("token", __state.get("token")); }
function onResponse() { __resp.setHeader("X-Test", "1"); }
function onStop() { __state.set("stopped", "yes"); }
`
	a := New(full, testLog)
	if a.Unavailable() {
		t.Fatal("valid source should not be unavailable")
	}
	a.OnStart([]byte{}, 8080, "test")
	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/", nil)
	a.OnRequest(req, "test")
	resp := &http.Response{Header: http.Header{}}
	a.OnResponse(resp, "test")
	a.OnStop("test")
	if req.URL.Query().Get("token") != "abc" {
		t.Fatalf("onRequest had no effect: %q", req.URL.RawQuery)
	}
	if resp.Header.Get("X-Test") != "1" {
		t.Fatal("onResponse had no effect")
	}
	if a.GetState().Get("stopped") != "yes" {
		t.Fatal("onStop had no effect")
	}

	partial := `function onStart() { __state.set("only", "start"); }`
	b := New(partial, testLog)
	b.OnStart([]byte{}, 8080, "test")
	partialReq := httptest.NewRequest("GET", "http://127.0.0.1:8080/keep?q=1", nil)
	b.OnRequest(partialReq, "test")
	partialResp := &http.Response{Header: http.Header{}}
	b.OnResponse(partialResp, "test")
	b.OnStop("test")
	if partialReq.URL.RawQuery != "q=1" || len(partialResp.Header) != 0 {
		t.Fatalf("absent hooks should be skipped: query=%q headers=%v", partialReq.URL.RawQuery, partialResp.Header)
	}
	if b.GetState().Get("only") != "start" {
		t.Fatal("the one defined hook should still run")
	}
}

func TestAdapterStatePersistsAcrossHooks(t *testing.T) {
	token := strings.Repeat("a1b2", 3)
	src := fmt.Sprintf(`
function onStart() { __state.set("token", "%s"); }
function onRequest() { __req.setQuery("token", __state.get("token")); }
`, token)
	a := New(src, testLog)
	a.OnStart([]byte("some stdout"), 8080, "dsh")

	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/", nil)
	a.OnRequest(req, "dsh")

	got := req.URL.Query().Get("token")
	if got != token {
		t.Fatalf("expected token=%s, got %q", token, got)
	}
}

// A throwing onStart must not stall the request path. The hook is not retried or
// waited out: the request is forwarded right away with the adapter still active,
// instead of every request paying readyTimeout before being forwarded anyway.
func TestAdapterOnStartErrorDoesNotStallRequests(t *testing.T) {
	src := `
function onStart() { throw new Error("boom"); }
function onRequest() { __req.setQuery("ran", "yes"); }
`
	a := New(src, testLog)
	a.OnStart([]byte{}, 8080, "test")

	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/", nil)
	started := time.Now()
	a.OnRequest(req, "test")
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("request waited %s after a failed onStart", elapsed)
	}
	if req.URL.Query().Get("ran") != "yes" {
		t.Fatal("the adapter should stay active after a failed onStart")
	}
}

// A throwing onRequest must not propagate and must leave the request as the
// proxy built it, so a broken adapter degrades to plain forwarding.
func TestAdapterOnRequestErrorLeavesRequestUntouched(t *testing.T) {
	src := `
function onStart() {}
function onRequest() { throw new Error("boom"); }
`
	a := New(src, testLog)
	a.OnStart([]byte{}, 8080, "test")

	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/path?keep=1", nil)
	a.OnRequest(req, "test")
	if req.URL.RawQuery != "keep=1" {
		t.Fatalf("a throwing onRequest should leave the request untouched, got %q", req.URL.RawQuery)
	}
}

func TestAdapterDSHEndToEnd(t *testing.T) {
	token := strings.Repeat("a1b2c3d4", 4)
	stdout := fmt.Sprintf(`dsh web: http://127.0.0.1:8080/?token=%s
Listening on 127.0.0.1:8080`, token)
	src := `
function onStart() {
    var m = __stdout.match(/token=([a-f0-9]+)/);
    if (m) __state.set("token", m[1]);
}
function onRequest() {
    var t = __state.get("token");
    if (t) __req.setQuery("token", t);
}
`
	a := New(src, testLog)
	a.OnStart([]byte(stdout), 8080, "dsh")

	extracted := a.GetState().Get("token")
	if extracted != token {
		t.Fatalf("expected token extracted, got %q", extracted)
	}

	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/", nil)
	a.OnRequest(req, "dsh")
	if got := req.URL.Query().Get("token"); got != token {
		t.Fatalf("expected token in query, got %q", got)
	}
}

func TestAdapterOnRequestAfterOnStart(t *testing.T) {
	src := `
function onStart() { __state.set("v", "1"); }
function onRequest() { __req.setQuery("v", __state.get("v")); }
`
	a := New(src, testLog)
	a.OnStart([]byte{}, 8080, "test")

	req := httptest.NewRequest("GET", "http://127.0.0.1:8080/", nil)
	a.OnRequest(req, "test")

	if req.URL.Query().Get("v") != "1" {
		t.Fatal("onRequest should see state from onStart")
	}
}

func TestAdapterOnResponseModifiesHeaders(t *testing.T) {
	src := `
function onStart() {}
function onResponse() { __resp.setHeader("X-Custom", "injected"); }
`
	a := New(src, testLog)
	a.OnStart([]byte{}, 8080, "test")

	resp := &http.Response{Header: http.Header{}}
	a.OnResponse(resp, "test")
	if resp.Header.Get("X-Custom") != "injected" {
		t.Fatal("onResponse should set header")
	}
}

func TestAdapterReqAndRespGetters(t *testing.T) {
	src := `
function onStart() {
    var m = __stdout.match(/token=([A-Za-z0-9_-]+)/);
    if (m) { __state.set("token", m[1]); }
}
function onRequest() {
    var t = __state.get("token");
    if (!t) return;
    var cookie = __req.getHeader("Cookie") || "";
    if (cookie.indexOf("dsh-auth-") === -1) {
        __req.setQuery("token", t);
    }
}
function onResponse() {
    var loc = __resp.getHeader("Location");
    if (loc) {
        __resp.setHeader("X-Redirected-From", loc);
    }
}
`
	a := New(src, testLog)
	a.OnStart([]byte("dsh web: http://127.0.0.1:58634/?token=My-Base64Url_Token123"), 58634, "dsh")

	// 1. First request has no session cookie: token should be injected
	req1 := httptest.NewRequest("GET", "http://127.0.0.1:58634/", nil)
	a.OnRequest(req1, "dsh")
	if req1.URL.Query().Get("token") != "My-Base64Url_Token123" {
		t.Fatalf("expected token injected on initial request, got %q", req1.URL.Query().Get("token"))
	}

	// 2. Second request already has dsh-auth- session cookie: token must NOT be injected
	req2 := httptest.NewRequest("GET", "http://127.0.0.1:58634/", nil)
	req2.Header.Set("Cookie", "dsh-auth-abc123=valid-session; other=value")
	a.OnRequest(req2, "dsh")
	if req2.URL.Query().Get("token") != "" {
		t.Fatalf("token should not be injected when session cookie is present, got %q", req2.URL.Query().Get("token"))
	}

	// 3. Response getter
	resp := &http.Response{Header: http.Header{"Location": []string{"/"}}}
	a.OnResponse(resp, "dsh")
	if resp.Header.Get("X-Redirected-From") != "/" {
		t.Fatalf("onResponse did not read Location header: %v", resp.Header)
	}
}

// The one header an application with a host allow-list lives or dies by: an adapter
// that sets Host must change the name the upstream sees, not an entry in a header map
// Go ignores when it sends the request.
func TestAdapterSetHeaderHostReachesTheUpstream(t *testing.T) {
	a := New(`function onRequest() { __req.setHeader("Host", "dsh.example.com"); }`, testLog)
	if a.Unavailable() {
		t.Fatal("valid source should not be unavailable")
	}
	// The node starts an app before it proxies to it; the adapter's first hook runs
	// then, and a request only follows once that has happened.
	a.OnStart([]byte{}, 8080, "test")
	req := httptest.NewRequest("GET", "http://192.168.1.6:6312/api/checkCleanIp", nil)
	req.Host = "192.168.1.6:6312"
	a.OnRequest(req, "test")
	if req.Host != "dsh.example.com" {
		t.Fatalf("the upstream would still be asked in the name %q", req.Host)
	}
}

// And the adapter every other app has: setting an ordinary header still works, and the
// name an entrance handed over is left alone unless an adapter asks otherwise.
func TestAdapterLeavesHostAloneByDefault(t *testing.T) {
	a := New(`function onRequest() { __req.setHeader("X-Test", "1"); }`, testLog)
	a.OnStart([]byte{}, 8080, "test")
	req := httptest.NewRequest("GET", "http://192.168.1.6:6312/", nil)
	req.Host = "192.168.1.6:6312"
	a.OnRequest(req, "test")
	if req.Host != "192.168.1.6:6312" {
		t.Fatalf("the entrance's Host was rewritten to %q", req.Host)
	}
	if req.Header.Get("X-Test") != "1" {
		t.Fatal("an ordinary header was not set")
	}
}
