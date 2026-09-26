package proxysecurity

import (
	"net/http"
	"testing"
)

// Every name this package reserves is one an application never sees, and the list
// is the only place that says which those are: a name that is set somewhere but
// missing here would leak through the proxy.
func TestStripInternalHeaders(t *testing.T) {
	header := http.Header{
		"Authorization":         []string{"secret"},
		ClientFingerprintHeader: []string{"fingerprint"},
		NodeHeader:              []string{"node"},
		"X-Application-Header":  []string{"preserved"},
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
