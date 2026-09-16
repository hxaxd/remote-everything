package main

import "testing"

// A public gateway is deployed by a systemd unit whose account owns its state,
// with a systemd timer holding its tunnel open and a Linux 443 entrance in front
// of it. Built for another system it can only ever be a gateway nobody finishes
// deploying, so the binary says so instead of starting.
func TestThePublicGatewayOnlyRunsOnLinux(t *testing.T) {
	if err := requireLinux("linux"); err != nil {
		t.Fatalf("Linux was refused: %v", err)
	}
	for _, goos := range []string{"windows", "darwin", "freebsd"} {
		if err := requireLinux(goos); err == nil {
			t.Fatalf("%s was accepted", goos)
		}
	}
}
