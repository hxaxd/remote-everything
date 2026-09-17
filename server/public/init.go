package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/secret"
	"github.com/hxaxd/remote-everything/internal/tunnelbootstrap"
)

// nodeTunnelHost and nodeTunnelPort are where this gateway reaches a node: the
// tunnel agent on that machine publishes its control port on the tunnel server's
// loopback, and this is the address the gateway dials and the port the agent is
// told to publish. What is recorded is the address, and the port in it is what
// the node's own tunnel configuration has to publish.
const (
	nodeTunnelHost = "127.0.0.1"
	nodeTunnelPort = 58628
)

type publicInitResult struct {
	OK             bool   `json:"ok"`
	State          string `json:"state"`
	InstallationID string `json:"installation_id"`
	Origin         string `json:"origin"`
	DeviceCAFile   string `json:"device_ca_file"`
	StatusListen   string `json:"status_listen"`
	PairingListen  string `json:"pairing_listen"`
	FRPSListen     string `json:"frps_listen"`
	FRPSTokenFile  string `json:"frps_token_file"`
	TunnelCAFile   string `json:"tunnel_ca_file"`
	DeviceIssuerDN string `json:"device_issuer_dn"`
	TunnelIssuerDN string `json:"tunnel_issuer_dn"`
}

type publicNodeResult struct {
	OK                      bool   `json:"ok"`
	State                   string `json:"state"`
	NodeID                  string `json:"node_id"`
	NodeName                string `json:"node_name"`
	NodeAddress             string `json:"node_address"`
	NodeBootstrap           string `json:"node_bootstrap"`
	TunnelMaterialDir       string `json:"tunnel_material_directory"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	RestartRequired         bool   `json:"restart_required"`
}

type publicNodeRemoveResult struct {
	OK              bool     `json:"ok"`
	State           string   `json:"state"`
	NodeID          string   `json:"node_id"`
	NodeName        string   `json:"node_name"`
	NodeAddress     string   `json:"node_address"`
	Devices         []string `json:"devices"`
	RestartRequired bool     `json:"restart_required"`
}

type publicTokenRenewResult struct {
	OK              bool   `json:"ok"`
	State           string `json:"state"`
	NodeID          string `json:"node_id"`
	NodeName        string `json:"node_name"`
	NodeAddress     string `json:"node_address"`
	NodeBootstrap   string `json:"node_bootstrap"`
	RestartRequired bool   `json:"restart_required"`
}

type publicRepairResult struct {
	OK              bool               `json:"ok"`
	State           string             `json:"state"`
	InstallationID  string             `json:"installation_id"`
	StatusListen    string             `json:"status_listen"`
	PairingListen   string             `json:"pairing_listen"`
	FRPSListen      string             `json:"frps_listen"`
	Nodes           []gatewaycore.Node `json:"nodes"`
	RestartRequired bool               `json:"restart_required"`
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

// allocationPreferences are the three loopback listeners a public gateway serves:
// the status port its own clients reach through the 443 entrance, the pairing
// port, and the frps upstream. Where each node is is not one of these: it is
// recorded with that node, because a gateway serves as many nodes as it was given
// and each has an address of its own. These preferences are what the gateway is
// initialized with, what its state must carry and what a repair moves the ports
// back to, so the three cannot drift apart.
func allocationPreferences() []gatewaycore.ListenerPreference {
	return []gatewaycore.ListenerPreference{
		{Name: "status", Host: "127.0.0.1", PreferredPort: 58629},
		{Name: "pairing", Host: "127.0.0.1", PreferredPort: 58631},
		{Name: "frps", Host: "127.0.0.1", PreferredPort: 58630},
	}
}

// listenerNames are the names of the listeners a public gateway serves, in the
// order its state records them.
func listenerNames() []string {
	preferences := allocationPreferences()
	names := make([]string, 0, len(preferences))
	for _, preference := range preferences {
		names = append(names, preference.Name)
	}
	return names
}

// preferredPorts is the port each listener is moved back to first when the ports
// are repaired.
func preferredPorts() map[string]int {
	preferred := make(map[string]int)
	for _, preference := range allocationPreferences() {
		preferred[preference.Name] = preference.PreferredPort
	}
	return preferred
}

func listen(state gatewaycore.State, name string) string {
	address, _ := state.Address(name)
	return address
}

// initializePublicState creates or reuses the gateway's own state. The origin is
// where the 443 entrance serves this gateway and therefore what every invitation
// this gateway hands out points at, so the operator states it once here rather
// than repeating it for every device. The nodes this gateway serves are added
// afterwards, one at a time, because each one is handed over to a machine of its
// own before it is part of this gateway.
func initializePublicState(root, origin string) (publicInitResult, error) {
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
		installationID, randomErr := secret.Hex(32)
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
	deviceIssuer, err := devicecore.EnsureIssuer(paths.root)
	if err != nil {
		return publicInitResult{}, err
	}
	if newState {
		if err := state.Save(paths.stateFile); err != nil {
			return publicInitResult{}, err
		}
	}
	material, err := tunnelbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID)
	if err != nil {
		return publicInitResult{}, err
	}
	return publicInitResult{
		OK: true, State: paths.root, InstallationID: state.InstallationID, Origin: state.Origin,
		DeviceCAFile: devicecore.IssuerCertPath(paths.root),
		StatusListen: listen(state, "status"), PairingListen: listen(state, "pairing"), FRPSListen: listen(state, "frps"),
		FRPSTokenFile: material.FRPSTokenFile, TunnelCAFile: material.CACertFile,
		DeviceIssuerDN: deviceIssuer.Subject.String(), TunnelIssuerDN: material.CACertificate.Subject.String(),
	}, nil
}

func runPublicInit(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	origin := flags.String("origin", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 {
		return errors.New("invalid init arguments")
	}
	result, err := initializePublicState(*state, *origin)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

// addPublicNode records one more node this gateway serves and hands its machine
// the identity bundle it binds this gateway with. Where the node is is this
// gateway's own tunnel: the address it records is a loopback port of its tunnel
// server, and the port in it is what that node's tunnel agent has to publish.
func addPublicNode(root, name, nodeID, bootstrapDir string) (publicNodeResult, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return publicNodeResult{}, errors.New("bootstrap path must be absolute")
	}
	nodeID = strings.ToLower(strings.TrimSpace(nodeID))
	name = strings.TrimSpace(name)
	if !gatewaycore.ValidNodeName(name) {
		return publicNodeResult{}, errors.New("invalid node name")
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		return publicNodeResult{}, err
	}
	state, err := paths.loadState()
	if err != nil {
		return publicNodeResult{}, err
	}
	material, err := tunnelbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID)
	if err != nil {
		return publicNodeResult{}, err
	}
	// A node that is already here keeps the address it was added with: the tunnel
	// agent on its machine publishes that port, and moving it would take the node
	// out of reach until that machine is told.
	address := ""
	if existing, ok := state.FindNode(nodeID); ok {
		address = existing.Address
	} else if address, err = state.AllocateNodeAddress(nodeTunnelHost, nodeTunnelPort); err != nil {
		return publicNodeResult{}, err
	}
	added, err := gatewaycore.DeliverNode(paths.root, state, gatewaycore.Node{ID: nodeID, Name: name, Address: address}, bootstrapDir)
	if err != nil {
		return publicNodeResult{}, err
	}
	tunnel, err := tunnelbootstrap.EnsureTunnelMaterial(bootstrapDir, material)
	if err != nil {
		return publicNodeResult{}, err
	}
	if err := added.Save(paths.stateFile); err != nil {
		return publicNodeResult{}, err
	}
	return publicNodeResult{
		OK: true, State: paths.root, NodeID: nodeID, NodeName: name, NodeAddress: address,
		NodeBootstrap: filepath.Clean(bootstrapDir), TunnelMaterialDir: tunnel.Directory,
		TunnelClientFingerprint: tunnel.Fingerprint, RestartRequired: true,
	}, nil
}

// removePublicNode takes a node out of this gateway: it stops serving it, it stops
// reaching it, and nothing a device holds says it may reach it any more. What is
// left on that machine — its binding, the tunnel agent publishing the port this
// gateway dialed — is the operator's to take down, and this gateway no longer has
// anything pointing at it.
func removePublicNode(root, nodeValue string) (publicNodeRemoveResult, error) {
	paths, err := newPublicPaths(root)
	if err != nil {
		return publicNodeRemoveResult{}, err
	}
	service, err := openPublicService(root)
	if err != nil {
		return publicNodeRemoveResult{}, err
	}
	node, err := gatewaycore.ResolveNode(service.state.Nodes, nodeValue)
	if err != nil {
		return publicNodeRemoveResult{}, err
	}
	reduced, err := service.state.RemoveNode(node.ID)
	if err != nil {
		return publicNodeRemoveResult{}, err
	}
	// The state goes first: a node the gateway no longer serves is unrouted at
	// once, and what is left behind by a failure — a device's list, a token file —
	// reaches nothing.
	if err := reduced.Save(paths.stateFile); err != nil {
		return publicNodeRemoveResult{}, err
	}
	devices, err := service.trust.ForgetNode(node.ID)
	if err != nil {
		return publicNodeRemoveResult{}, err
	}
	if err := gatewaycore.RemoveNodeToken(paths.root, node.ID); err != nil {
		return publicNodeRemoveResult{}, fmt.Errorf("the node was removed, but its control token could not be deleted: %w", err)
	}
	return publicNodeRemoveResult{
		OK: true, State: paths.root, NodeID: node.ID, NodeName: node.Name, NodeAddress: node.Address,
		Devices: devices, RestartRequired: true,
	}, nil
}

// renewPublicNodeToken replaces the control token of a node this gateway serves
// and hands that machine the bundle carrying it. Which node it is, and where it is,
// do not change: this is for the machine that was given a token and should not have
// it any more.
func renewPublicNodeToken(root, nodeValue, bootstrapDir string) (publicTokenRenewResult, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return publicTokenRenewResult{}, errors.New("node bootstrap path must be absolute")
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		return publicTokenRenewResult{}, err
	}
	state, err := paths.loadState()
	if err != nil {
		return publicTokenRenewResult{}, err
	}
	node, err := gatewaycore.ResolveNode(state.Nodes, nodeValue)
	if err != nil {
		return publicTokenRenewResult{}, err
	}
	// The state does not change — the node is the same node — so it is not written
	// again; what changes is the token, and the bundle that carries it.
	if _, err := gatewaycore.DeliverRotatedNode(paths.root, state, node, bootstrapDir); err != nil {
		return publicTokenRenewResult{}, err
	}
	return publicTokenRenewResult{
		OK: true, State: paths.root, NodeID: node.ID, NodeName: node.Name, NodeAddress: node.Address,
		NodeBootstrap: filepath.Clean(bootstrapDir), RestartRequired: true,
	}, nil
}

func runPublicNode(parts []string, output io.Writer) error {
	if len(parts) == 0 {
		return errors.New("missing node action")
	}
	if len(parts) >= 2 && parts[0] == "token" && parts[1] == "renew" {
		return runPublicNodeTokenRenew(parts[2:], output)
	}
	flags := flag.NewFlagSet("node "+parts[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	name := flags.String("name", "", "")
	nodeID := flags.String("node-id", "", "")
	node := flags.String("node", "", "")
	bootstrapDir := flags.String("node-bootstrap", "", "")
	if flags.Parse(parts[1:]) != nil || flags.NArg() != 0 {
		return errors.New("invalid node arguments")
	}
	switch parts[0] {
	case "add":
		if *name == "" || *nodeID == "" || *bootstrapDir == "" {
			return errors.New("invalid node add arguments")
		}
		result, err := addPublicNode(*state, *name, *nodeID, *bootstrapDir)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(result)
	case "list":
		if *name != "" || *nodeID != "" || *node != "" || *bootstrapDir != "" {
			return errors.New("invalid node list arguments")
		}
		paths, err := newPublicPaths(*state)
		if err != nil {
			return err
		}
		stored, err := paths.loadState()
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(stored.Nodes)
	case "remove":
		if *node == "" || *name != "" || *nodeID != "" || *bootstrapDir != "" {
			return errors.New("invalid node remove arguments")
		}
		result, err := removePublicNode(*state, *node)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(result)
	default:
		return errors.New("unknown node action")
	}
}

func runPublicNodeTokenRenew(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("node token renew", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	node := flags.String("node", "", "")
	bootstrapDir := flags.String("node-bootstrap", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 || *node == "" || *bootstrapDir == "" {
		return errors.New("invalid node token renew arguments")
	}
	result, err := renewPublicNodeToken(*state, *node, *bootstrapDir)
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
func renewTunnelIdentity(root, nodeBootstrap string) (tunnelRenewResult, error) {
	paths, err := newPublicPaths(root)
	if err != nil {
		return tunnelRenewResult{}, err
	}
	state, err := paths.loadState()
	if err != nil {
		return tunnelRenewResult{}, err
	}
	material, err := tunnelbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID)
	if err != nil {
		return tunnelRenewResult{}, err
	}
	tunnel, err := tunnelbootstrap.RenewTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return tunnelRenewResult{}, err
	}
	return tunnelRenewResult{
		OK: true, InstallationID: state.InstallationID,
		NodeBootstrap: filepath.Clean(nodeBootstrap), TunnelCAFile: material.CACertFile,
		TunnelIssuerDN:    material.CACertificate.Subject.String(),
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
	}, nil
}

// repairPublicPorts moves every port this gateway owns: its listeners and the
// tunnel port of each node, which are this gateway's to move because its own
// tunnel server holds them. Each node's id and name stay, and so does the frpc
// configuration's name for it, so the machines behind them only have to be told
// the new port.
func repairPublicPorts(root string) (publicRepairResult, error) {
	paths, err := newPublicPaths(root)
	if err != nil {
		return publicRepairResult{}, err
	}
	state, err := paths.loadState()
	if err != nil {
		return publicRepairResult{}, err
	}
	repaired, err := state.Repair(preferredPorts())
	if err != nil {
		return publicRepairResult{}, err
	}
	if repaired, err = repaired.RepairNodePorts(nodeTunnelPort); err != nil {
		return publicRepairResult{}, err
	}
	if err := repaired.Save(paths.stateFile); err != nil {
		return publicRepairResult{}, err
	}
	return publicRepairResult{
		OK: true, State: paths.root, InstallationID: repaired.InstallationID,
		StatusListen: listen(repaired, "status"), PairingListen: listen(repaired, "pairing"), FRPSListen: listen(repaired, "frps"),
		Nodes: repaired.Nodes, RestartRequired: true,
	}, nil
}
