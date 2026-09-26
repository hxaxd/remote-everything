package wire

import (
	"strings"
	"testing"
)

// An application id is one hostname label, because a public gateway serves an
// application at a host built under its own domain and the id is that host's
// first label: an id that could not be a label would name an application half
// of the deployment cannot open, so it is not an id anywhere.
func TestAnApplicationIDIsAHostnameLabel(t *testing.T) {
	for _, id := range []string{"editor", "dsh", "a", "a1", "0app", strings.Repeat("a", 63)} {
		if !ValidAppID(id) {
			t.Fatalf("the application id %q was refused", id)
		}
	}
	for _, id := range []string{
		"",
		"my.app", // a dot is another label, and the host would not parse back
		"my_app", // an underscore is no label
		"-app",   // a label does not begin with a hyphen
		"app-",   // a label does not end with one
		"Editor", // ids are lowercase, the way a host is
		strings.Repeat("a", 64),
	} {
		if ValidAppID(id) {
			t.Fatalf("the application id %q was accepted", id)
		}
	}
}
