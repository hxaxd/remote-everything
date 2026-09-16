package netaddr

import (
	"net"
	"strconv"
	"testing"
)

func TestValidAcceptsOnlyTheRequestedHostAndAUsablePort(t *testing.T) {
	for _, testCase := range []struct {
		address string
		host    string
		valid   bool
	}{
		{"127.0.0.1:58627", "127.0.0.1", true},
		{"127.0.0.1:1024", "127.0.0.1", true},
		{"127.0.0.1:65535", "127.0.0.1", true},
		{"0.0.0.0:58626", "0.0.0.0", true},
		{"127.0.0.1:1023", "127.0.0.1", false},
		{"127.0.0.1:65536", "127.0.0.1", false},
		{"127.0.0.1:", "127.0.0.1", false},
		{"127.0.0.1:port", "127.0.0.1", false},
		{"0.0.0.0:58626", "127.0.0.1", false},
		{"127.0.0.1:58626", "0.0.0.0", false},
		{"127.0.0.1", "127.0.0.1", false},
	} {
		if got := Valid(testCase.address, testCase.host); got != testCase.valid {
			t.Errorf("Valid(%q, %q) = %v, want %v", testCase.address, testCase.host, got, testCase.valid)
		}
	}
}

func TestValidLoopbackRejectsAWildcardAddress(t *testing.T) {
	if ValidLoopback("0.0.0.0:58626") {
		t.Fatal("a wildcard address is not a loopback address")
	}
	if !ValidLoopback("127.0.0.1:58626") {
		t.Fatal("a loopback address was rejected")
	}
}

func TestReserveTakesThePreferredPortWhenItIsFree(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	preferred := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	address, err := Reserve("127.0.0.1", preferred)
	if err != nil {
		t.Fatal(err)
	}
	if address != net.JoinHostPort("127.0.0.1", strconv.Itoa(preferred)) {
		t.Fatalf("Reserve returned %q, want the preferred port %d", address, preferred)
	}
}

func TestReserveFallsBackWhenThePreferredPortIsTaken(t *testing.T) {
	held, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	taken := held.Addr().(*net.TCPAddr).Port
	address, err := Reserve("127.0.0.1", taken)
	if err != nil {
		t.Fatal(err)
	}
	if address == net.JoinHostPort("127.0.0.1", strconv.Itoa(taken)) {
		t.Fatalf("Reserve returned the port that is already in use: %q", address)
	}
	if !Valid(address, "127.0.0.1") {
		t.Fatalf("Reserve returned an unusable address %q", address)
	}
}

func TestReserveHonoursTheRequestedHost(t *testing.T) {
	address, err := Reserve("0.0.0.0")
	if err != nil {
		t.Fatal(err)
	}
	if !Valid(address, "0.0.0.0") {
		t.Fatalf("Reserve returned %q for host 0.0.0.0", address)
	}
}
