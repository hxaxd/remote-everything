package main

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
)

const publicStateSchema = 1

var validHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

type publicPaths struct {
	root             string
	controlTokenFile string
	devicesDir       string
	invitesDir       string
	issuerKeyFile    string
	issuerCertFile   string
	stateFile        string
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
		root: root, controlTokenFile: filepath.Join(root, "control-token"), devicesDir: filepath.Join(root, "devices"),
		invitesDir: filepath.Join(root, "invites"), issuerKeyFile: filepath.Join(root, "device-issuer.key.pem"),
		issuerCertFile: filepath.Join(root, "device-issuer.crt.pem"), stateFile: filepath.Join(root, "server.json"),
	}, nil
}

func validPublicLoopback(address string) bool {
	host, portText, err := net.SplitHostPort(address)
	if err != nil || host != "127.0.0.1" {
		return false
	}
	port, err := strconv.Atoi(portText)
	return err == nil && port >= 1024 && port <= 65535
}

func decodePublicJSON(path string, output any) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("trailing JSON content")
	}
	return nil
}

func (paths publicPaths) loadState() (publicState, error) {
	var state publicState
	if err := decodePublicJSON(paths.stateFile, &state); err != nil {
		return publicState{}, err
	}
	addresses := []string{state.StatusListen, state.PairingListen, state.FRPSListen, state.NodeTunnelListen}
	seen := map[string]bool{}
	for _, address := range addresses {
		if !validPublicLoopback(address) || seen[address] {
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
