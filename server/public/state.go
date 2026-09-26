package main

import (
	"errors"
	"path/filepath"

	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/infra/netaddr"
)

// publicPaths is what the entrance keeps in its own root. The device CA, the
// device records and the invitations live there too, but they belong to the
// device trust and are named by it.
type publicPaths struct {
	root      string
	stateFile string
}

func newPublicPaths(root string) (publicPaths, error) {
	if !filepath.IsAbs(root) {
		return publicPaths{}, errors.New("state path must be absolute")
	}
	root = filepath.Clean(root)
	return publicPaths{root: root, stateFile: filepath.Join(root, "server.json")}, nil
}

func (paths publicPaths) loadState() (gatewaycore.State, error) {
	state, err := gatewaycore.LoadState(paths.stateFile)
	if err != nil {
		return gatewaycore.State{}, err
	}
	// This gateway terminates nothing: what it serves is reached through the
	// entrance in front of it, so every one of its listeners — and every node,
	// which it reaches over its own tunnel — is on loopback.
	for _, name := range listenerNames() {
		address, err := state.Address(name)
		if err != nil || !netaddr.ValidLoopback(address) {
			return gatewaycore.State{}, errors.New("invalid public server state")
		}
	}
	for _, node := range state.Nodes {
		if !netaddr.ValidLoopback(node.Address) {
			return gatewaycore.State{}, errors.New("invalid public server state")
		}
	}
	return state, nil
}
