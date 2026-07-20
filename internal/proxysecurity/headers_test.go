package proxysecurity

import (
	"net/http"
	"testing"
)

func TestStripInternalHeaders(t *testing.T) {
	header := http.Header{
		"Authorization":                          []string{"secret"},
		"X-Remote-Everything-Client-Fingerprint": []string{"fingerprint"},
		"X-Remote-Everything-Control-Token":      []string{"token"},
		"X-Application-Header":                   []string{"preserved"},
	}
	StripInternalHeaders(header)
	for _, name := range internalHeaderNames {
		if header.Get(name) != "" {
			t.Fatalf("internal header %q was preserved", name)
		}
	}
	if header.Get("Authorization") != "secret" {
		t.Fatal("application authorization header was removed")
	}
	if header.Get("X-Application-Header") != "preserved" {
		t.Fatal("application header was removed")
	}
}
