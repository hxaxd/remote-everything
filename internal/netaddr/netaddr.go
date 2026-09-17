// Package netaddr allocates and checks the loopback and LAN addresses the node
// and the gateways listen on. Every address in this project is a dynamic one:
// callers state a preference, the operating system decides, and the chosen
// address is persisted so a restart keeps it.
package netaddr

import (
	"errors"
	"net"
	"strconv"
)

const (
	minPort = 1024
	maxPort = 65535
)

// Valid reports whether address is host:port for exactly this host and a port
// in the range this project allocates from.
func Valid(address, host string) bool {
	addressHost, portText, err := net.SplitHostPort(address)
	if err != nil || addressHost != host {
		return false
	}
	port, err := strconv.Atoi(portText)
	return err == nil && port >= minPort && port <= maxPort
}

// ValidLoopback reports whether address is a loopback address a gateway or node
// can listen on.
func ValidLoopback(address string) bool {
	return Valid(address, "127.0.0.1")
}

// ValidLoopbackHost reports whether host is a loopback address: the machine the
// request came from is this one, which is what an entrance standing in front of a
// gateway looks like from behind it.
func ValidLoopbackHost(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// ValidUnicastHost reports whether host is an IPv4 address a peer can dial.
func ValidUnicastHost(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.To4() != nil && !ip.IsUnspecified() && !ip.IsMulticast()
}

// ValidUnicast reports whether address is a specific address a peer can dial: an
// IPv4 address that is neither unspecified nor multicast, with a port in the
// range this project allocates from. A node that a gateway on another machine
// has to reach listens on such an address, and the exact value is what the
// gateway is configured with.
func ValidUnicast(address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	return ValidUnicastHost(host) && Valid(address, host)
}

// ValidListen reports whether address is one a gateway may serve on: the
// wildcard address or a specific IPv4 address, with a port this project
// allocates from. A gateway that fronts its own clients may listen on every
// interface; one behind an entrance listens where that entrance reaches it.
func ValidListen(address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return false
	}
	if host != "0.0.0.0" && !ValidUnicastHost(host) {
		return false
	}
	return Valid(address, host)
}

// Reserve returns an available address on host. Each preferred port is tried in
// order; when none of them is available the operating system picks one.
func Reserve(host string, preferred ...int) (string, error) {
	for _, port := range preferred {
		if address, err := probe(host, port); err == nil {
			return address, nil
		}
	}
	address, err := probe(host, 0)
	if err != nil {
		return "", errors.New("no port available on " + host)
	}
	return address, nil
}

func probe(host string, port int) (string, error) {
	listener, err := net.Listen("tcp4", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return "", err
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		return "", err
	}
	if !Valid(address, host) {
		return "", errors.New("unusable address " + address)
	}
	return address, nil
}
