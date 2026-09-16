package main

import (
	"errors"
	"path/filepath"
	"regexp"

	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"github.com/hxaxd/remote-everything/internal/netaddr"
)

const publicStateSchema = 1

var validHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

type publicPaths struct {
	root           string
	devicesDir     string
	invitesDir     string
	issuerKeyFile  string
	issuerCertFile string
	stateFile      string
}

type publicState struct {
	Schema           int    `json:"schema"`
	InstallationID   string `json:"installation_id"`
	StatusListen     string `json:"status_listen"`
	PairingListen    string `json:"pairing_listen"`
	FRPSListen       string `json:"frps_listen"`
	NodeTunnelListen string `json:"node_tunnel_listen"`
}

func newPublicPaths(root string) (publicPaths, error) {
	if !filepath.IsAbs(root) {
		return publicPaths{}, errors.New("state path must be absolute")
	}
	root = filepath.Clean(root)
	return publicPaths{
		root: root, devicesDir: filepath.Join(root, "devices"),
		invitesDir: filepath.Join(root, "invites"), issuerKeyFile: filepath.Join(root, "device-issuer.key.pem"),
		issuerCertFile: filepath.Join(root, "device-issuer.crt.pem"), stateFile: filepath.Join(root, "server.json"),
	}, nil
}

func (paths publicPaths) loadState() (publicState, error) {
	var state publicState
	if err := jsonfile.Read(paths.stateFile, &state); err != nil {
		return publicState{}, err
	}
	addresses := []string{state.StatusListen, state.PairingListen, state.FRPSListen, state.NodeTunnelListen}
	seen := map[string]bool{}
	for _, address := range addresses {
		if !netaddr.ValidLoopback(address) || seen[address] {
			return publicState{}, errors.New("invalid public server state")
		}
		seen[address] = true
	}
	if state.Schema != publicStateSchema || !validHex64.MatchString(state.InstallationID) {
		return publicState{}, errors.New("invalid public server state")
	}
	return state, nil
}

func openPublicService(root string) (*publicService, error) {
	paths, err := newPublicPaths(root)
	if err != nil {
		return nil, err
	}
	state, err := paths.loadState()
	if err != nil {
		return nil, err
	}
	return newPublicService(paths, state), nil
}
