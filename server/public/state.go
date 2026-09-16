package main

import (
	"errors"
	"path/filepath"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/netaddr"
)

// publicPaths is what the entrance keeps in its own root. The device CA, the
// device records and the invitations live there too, but they belong to the
// device trust and are named by it.
type publicPaths struct {
	root      string
	stateFile string
}

// listenerNames are the listeners a public gateway serves. The state file is
// the shared gateway state; these are the names it must carry, and the CLI and
// the deployment templates address them by name.
var listenerNames = []string{"status", "pairing", "frps", "node_tunnel"}

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
	for _, name := range listenerNames {
		address, err := state.Address(name)
		if err != nil || !netaddr.ValidLoopback(address) {
			return gatewaycore.State{}, errors.New("invalid public server state")
		}
	}
	return state, nil
}
