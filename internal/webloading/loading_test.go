package webloading

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestApplicationDocument(t *testing.T) {
	for _, tc := range []struct {
		name, theme, kind, encoding, body string
		status                            int
		inject                            bool
	}{
		{"dark", "dark", "text/html; charset=utf-8", "", "<!doctype html><HTML><HEAD><title>App</title></HEAD><body>App</body></HTML>", 200, true},
		{"light", "light", "text/html", "", "<head lang=\"en\"></head><body>App</body>", 200, true},
		{"native", "", "text/html", "", "<head></head><body>App</body>", 200, false},
		{"api", "dark", "application/json", "", `{"ok":true}`, 200, false},
		{"compressed", "dark", "text/html", "br", "compressed bytes", 200, false},
		{"redirect", "dark", "text/html", "", "<head></head>", 303, false},
		{"fragment", "dark", "text/html", "", "<div>partial response</div>", 200, false},
		{"long-prefix", "dark", "text/html", "", strings.Repeat("x", 70000) + "<head></head>", 200, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "https://app.test/", nil)
			r.Header.Set("Accept", "text/html")
			r.Header.Set("Accept-Encoding", "gzip")
			r.Header.Set("If-None-Match", "old")
			r = WithTheme(r, tc.theme)
			Prepare(r)
			if tc.theme != "" && (r.Header.Get("Accept-Encoding") != "identity" || r.Header.Get("If-None-Match") != "") {
				t.Fatal("document preparation failed")
			}
			h := http.Header{"Content-Type": {tc.kind}, "Content-Encoding": {tc.encoding}, "Content-Length": {"123"}, "ETag": {"old"}, "Content-Security-Policy": {"script-src 'nonce-testNonce123'"}}
			response := &http.Response{Request: r, StatusCode: tc.status, Header: h, Body: io.NopCloser(strings.NewReader(tc.body)), ContentLength: 123}
			if err := Apply(response); err != nil {
				t.Fatal(err)
			}
			result, _ := io.ReadAll(response.Body)
			response.Body.Close()
			if tc.inject {
				if !strings.Contains(string(result), `data-scheme="`+tc.theme+`" nonce="testNonce123"`) || response.ContentLength != -1 || h.Get("ETag") != "" {
					t.Fatal("missing cover or stale content metadata")
				}
				start := strings.Index(string(result), `<meta name="color-scheme"`)
				end := strings.Index(string(result), `</script>`) + len(`</script>`)
				if string(result[:start])+string(result[end:]) != tc.body {
					t.Fatal("application document changed")
				}
				if h.Get("Content-Security-Policy") != "script-src 'nonce-testNonce123'" {
					t.Fatal("CSP changed")
				}
			} else if string(result) != tc.body {
				t.Fatal("pass-through bytes changed")
			}
		})
	}
}
