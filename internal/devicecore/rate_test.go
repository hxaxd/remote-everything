package devicecore

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// What a request is counted against: the client, not whichever machine relayed it.
// A gateway behind an entrance sees every device arrive from the entrance, so
// counting the peer would put the whole deployment in one bucket.
func TestClientIPIsTheClientRatherThanTheRelay(t *testing.T) {
	for name, testCase := range map[string]struct {
		remoteAddr string
		forwarded  string
		expected   string
	}{
		"an entrance names the client it saw": {
			remoteAddr: "127.0.0.1:54321", forwarded: "203.0.113.7", expected: "203.0.113.7",
		},
		"the last name is the entrance's own": {
			remoteAddr: "127.0.0.1:54321", forwarded: "9.9.9.9, 203.0.113.7", expected: "203.0.113.7",
		},
		"a client that arrives directly is its own peer": {
			remoteAddr: "192.168.1.9:40000", forwarded: "9.9.9.9", expected: "192.168.1.9",
		},
		"a direct client is not believed about itself": {
			remoteAddr: "192.168.1.9:40000", forwarded: "", expected: "192.168.1.9",
		},
		"an entrance that names nobody leaves the peer": {
			remoteAddr: "127.0.0.1:54321", forwarded: "", expected: "127.0.0.1",
		},
		"an entrance that names nobody twice leaves the peer": {
			remoteAddr: "127.0.0.1:54321", forwarded: " , ", expected: "127.0.0.1",
		},
		"a request with no port is itself": {
			remoteAddr: "203.0.113.7", forwarded: "", expected: "203.0.113.7",
		},
		"an entrance over IPv6 loopback is an entrance": {
			remoteAddr: "[::1]:54321", forwarded: "203.0.113.7", expected: "203.0.113.7",
		},
	} {
		request := httptest.NewRequest(http.MethodPost, "/__remote_everything_pair", nil)
		request.RemoteAddr = testCase.remoteAddr
		if testCase.forwarded != "" {
			request.Header.Set("X-Forwarded-For", testCase.forwarded)
		}
		if got := ClientAddress(request); got != testCase.expected {
			t.Errorf("%s: counted against %q, want %q", name, got, testCase.expected)
		}
	}
}
