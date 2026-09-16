package main

import (
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"

	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

type publicInitResult struct {
	OK                      bool   `json:"ok"`
	State                   string `json:"state"`
	InstallationID          string `json:"installation_id"`
	Origin                  string `json:"origin"`
	ControlTokenFile        string `json:"control_token_file"`
	DeviceCAFile            string `json:"device_ca_file"`
	StatusListen            string `json:"status_listen"`
	PairingListen           string `json:"pairing_listen"`
	FRPSListen              string `json:"frps_listen"`
	NodeTunnelListen        string `json:"node_tunnel_listen"`
	NodeBootstrap           string `json:"node_bootstrap"`
	FRPSTokenFile           string `json:"frps_token_file"`
	TunnelCAFile            string `json:"tunnel_ca_file"`
	TunnelMaterialDir       string `json:"tunnel_material_directory"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	DeviceIssuerDN          string `json:"device_issuer_dn"`
	TunnelIssuerDN          string `json:"tunnel_issuer_dn"`
}

type tunnelRenewResult struct {
	OK                      bool   `json:"ok"`
	InstallationID          string `json:"installation_id"`
	NodeBootstrap           string `json:"node_bootstrap"`
	TunnelCAFile            string `json:"tunnel_ca_file"`
	TunnelMaterialDir       string `json:"tunnel_material_directory"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	TunnelIssuerDN          string `json:"tunnel_issuer_dn"`
}

// allocationPreferences are the four distinct loopback listeners a public
// gateway serves: the status port its own clients reach through the 443
// entrance, the pairing port, the frps upstream, and the port the tunnel brings
// the node's control channel in on.
func allocationPreferences() []gatewaycore.ListenerPreference {
	return []gatewaycore.ListenerPreference{
		{Name: "status", Host: "127.0.0.1", PreferredPort: 58629},
		{Name: "pairing", Host: "127.0.0.1", PreferredPort: 58631},
		{Name: "frps", Host: "127.0.0.1", PreferredPort: 58630},
		{Name: "node_tunnel", Host: "127.0.0.1", PreferredPort: 58628},
	}
}

func listen(state gatewaycore.State, name string) string {
	address, _ := state.Address(name)
	return address
}

// initializePublicState creates or reuses the gateway's own state. The origin is
// where the 443 entrance serves this gateway and therefore what every invitation
// this gateway hands out points at, so the operator states it once here rather
// than repeating it for every device.
func initializePublicState(root, nodeBootstrap, origin string) (publicInitResult, error) {
	if !filepath.IsAbs(nodeBootstrap) {
		return publicInitResult{}, errors.New("node bootstrap path must be absolute")
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		return publicInitResult{}, err
	}
	normalizedOrigin, err := gatewaycore.NormalizeOrigin(origin)
	if err != nil {
		return publicInitResult{}, err
	}
	state, err := paths.loadState()
	newState := errors.Is(err, os.ErrNotExist)
	if newState {
		installationID, randomErr := gatewaycore.NewSecret()
		if randomErr != nil {
			return publicInitResult{}, randomErr
		}
		listeners, allocateErr := gatewaycore.AllocateListeners(allocationPreferences())
		if allocateErr != nil {
			return publicInitResult{}, allocateErr
		}
		state, err = gatewaycore.NewState(installationID, normalizedOrigin, listeners)
		if err != nil {
			return publicInitResult{}, err
		}
	} else if err != nil {
		return publicInitResult{}, err
	} else if state.Origin != normalizedOrigin {
		return publicInitResult{}, errors.New("existing gateway serves another origin")
	}
	controlToken, err := gatewaycore.EnsureControlToken(paths.root)
	if err != nil {
		return publicInitResult{}, err
	}
	deviceIssuer, err := devicecore.EnsureIssuer(paths.root)
	if err != nil {
		return publicInitResult{}, err
	}
	if newState {
		if err := state.Save(paths.stateFile); err != nil {
			return publicInitResult{}, err
		}
	}
	material, err := deploymentbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID, controlToken)
	if err != nil {
		return publicInitResult{}, err
	}
	identity := gatewaycore.Identity{InstallationID: state.InstallationID, ControlToken: controlToken}
	if err := identity.WriteBundle(nodeBootstrap); err != nil {
		return publicInitResult{}, err
	}
	tunnel, err := deploymentbootstrap.EnsureTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return publicInitResult{}, err
	}
	return publicInitResult{
		OK: true, State: paths.root, InstallationID: state.InstallationID, Origin: state.Origin,
		ControlTokenFile: gatewaycore.ControlTokenPath(paths.root), DeviceCAFile: devicecore.IssuerCertPath(paths.root),
		StatusListen: listen(state, "status"), PairingListen: listen(state, "pairing"),
		FRPSListen: listen(state, "frps"), NodeTunnelListen: listen(state, "node_tunnel"),
		NodeBootstrap: filepath.Clean(nodeBootstrap), FRPSTokenFile: material.FRPSTokenFile, TunnelCAFile: material.CACertFile,
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
		DeviceIssuerDN: deviceIssuer.Subject.String(), TunnelIssuerDN: material.CACertificate.Subject.String(),
	}, nil
}

func runPublicInit(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	nodeBootstrap := flags.String("node-bootstrap", "", "")
	origin := flags.String("origin", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 {
		return errors.New("invalid init arguments")
	}
	result, err := initializePublicState(*state, *nodeBootstrap, *origin)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

// renewTunnelIdentity issues a new client identity for the tunnel into the
// handover bundle the operator already carries to the node machine. The node
// takes no part in it: neither the identity the gateway is bound by nor the
// tunnel CA changes, so only the tunnel agent has to be pointed at the newly
// delivered files and restarted.
func renewTunnelIdentity(root, nodeBootstrap string, output io.Writer) error {
	paths, err := newPublicPaths(root)
	if err != nil {
		return err
	}
	state, err := paths.loadState()
	if err != nil {
		return err
	}
	controlToken, err := gatewaycore.ReadControlToken(paths.root)
	if err != nil {
		return err
	}
	material, err := deploymentbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID, controlToken)
	if err != nil {
		return err
	}
	tunnel, err := deploymentbootstrap.RenewTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(tunnelRenewResult{
		OK: true, InstallationID: state.InstallationID,
		NodeBootstrap: filepath.Clean(nodeBootstrap), TunnelCAFile: material.CACertFile,
		TunnelIssuerDN:    material.CACertificate.Subject.String(),
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
	})
}

func repairPublicPorts(root string, output io.Writer) error {
	paths, err := newPublicPaths(root)
	if err != nil {
		return err
	}
	state, err := paths.loadState()
	if err != nil {
		return err
	}
	repaired, err := state.Repair(map[string]int{"status": 58629, "pairing": 58631, "frps": 58630, "node_tunnel": 58628})
	if err != nil {
		return err
	}
	if err := repaired.Save(paths.stateFile); err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(publicInitResult{
		OK: true, State: paths.root, InstallationID: state.InstallationID, Origin: state.Origin,
		ControlTokenFile: gatewaycore.ControlTokenPath(paths.root), DeviceCAFile: devicecore.IssuerCertPath(paths.root),
		StatusListen: listen(state, "status"), PairingListen: listen(state, "pairing"),
		FRPSListen: listen(state, "frps"), NodeTunnelListen: listen(state, "node_tunnel"),
	})
}
