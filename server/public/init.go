package main

import (
	"encoding/json"
	"errors"
	"flag"
	"io"
	"os"

	"github.com/hxaxd/remote-everything/internal/backplane/tunnelbootstrap"
	"github.com/hxaxd/remote-everything/internal/gateway/devicecore"
	"github.com/hxaxd/remote-everything/internal/gateway/entrance"
	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/infra/secret"
)

// nodeTunnelHost and nodeTunnelPort are where this gateway reaches a node: the
// tunnel agent on that machine publishes its control port on the tunnel server's
// loopback, and this is the address the gateway dials and the port the agent is
// told to publish. What is recorded is the address, and the port in it is what
// the node's own tunnel configuration has to publish.
const (
	nodeTunnelHost = tunnelbootstrap.NodeTunnelHost
	nodeTunnelPort = tunnelbootstrap.NodeTunnelPort
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

// publicNodes is this gateway's state as the node lifecycle sees it: the
// shape's part of the work every gateway shares.
type publicNodes struct {
	root  string
	state gatewaycore.State
}

// openPublicNodes opens this gateway's state for a node command.
func openPublicNodes(root string) (entrance.NodeShape, error) {
	return &publicNodes{root: root}, nil
}

func (nodes *publicNodes) State() (gatewaycore.State, error) {
	paths, err := newPublicPaths(nodes.root)
	if err != nil {
		return gatewaycore.State{}, err
	}
	state, err := paths.loadState()
	if err != nil {
		return gatewaycore.State{}, err
	}
	nodes.state = state
	return state, nil
}

func (nodes *publicNodes) Save(state gatewaycore.State) error {
	paths, err := newPublicPaths(nodes.root)
	if err != nil {
		return err
	}
	return state.Save(paths.stateFile)
}

func (nodes *publicNodes) Trust() (*devicecore.Trust, error) {
	paths, err := newPublicPaths(nodes.root)
	if err != nil {
		return nil, err
	}
	state, err := paths.loadState()
	if err != nil {
		return nil, err
	}
	return openPublicTrust(paths.root, state, nil)
}

// PlaceNode is where a node of this gateway lives: a loopback port of its own
// tunnel, which is the whole of where a public gateway reaches anything. There
// is no node a pointer from the operator could name instead.
func (nodes *publicNodes) PlaceNode(nodeID, address string) (gatewaycore.State, entrance.Placement, error) {
	if address != "" {
		return gatewaycore.State{}, entrance.Placement{}, errors.New("a public gateway reaches its nodes over its own tunnel; node add takes no node address")
	}
	material, err := tunnelbootstrap.EnsureGatewayMaterial(nodes.root, nodes.state.InstallationID)
	if err != nil {
		return gatewaycore.State{}, entrance.Placement{}, err
	}
	// A node that is already here keeps the address it was added with: the
	// tunnel agent on its machine publishes that port, and moving it would
	// take the node out of reach until that machine is told.
	where := ""
	if existing, ok := nodes.state.FindNode(nodeID); ok {
		where = existing.Address
	} else if where, err = nodes.state.AllocateNodeAddress(nodeTunnelHost, nodeTunnelPort); err != nil {
		return gatewaycore.State{}, entrance.Placement{}, err
	}
	return nodes.state, entrance.Placement{Address: where, Tunnel: &material}, nil
}

// TookNodeAway takes nothing of its own with the node: what a public gateway
// holds for a node is the record, the devices' grants and the control token,
// and the lifecycle takes all three.
func (nodes *publicNodes) TookNodeAway(nodeID string) error {
	return nil
}

// TunnelMaterial is this gateway's tunnel material, which it always has: the
// tunnel is how it reaches everything it serves.
func (nodes *publicNodes) TunnelMaterial() (tunnelbootstrap.GatewayMaterial, error) {
	return tunnelbootstrap.EnsureGatewayMaterial(nodes.root, nodes.state.InstallationID)
}

// addPublicNode records one more node this gateway serves and hands its
// machine the identity bundle it binds this gateway with.
func addPublicNode(root, name, nodeID, link, bootstrapDir string) (entrance.NodeResult, error) {
	return entrance.AddNode(&publicNodes{root: root}, root, name, nodeID, "", link, bootstrapDir)
}

// removePublicNode takes a node out of this gateway.
func removePublicNode(root, nodeValue string) (entrance.NodeRemoveResult, error) {
	return entrance.RemoveNode(&publicNodes{root: root}, root, nodeValue)
}

// renewPublicNodeToken replaces the control token of a node this gateway
// serves and hands that machine the bundle carrying it.
func renewPublicNodeToken(root, nodeValue, bootstrapDir string) (entrance.TokenRenewResult, error) {
	return entrance.RenewNodeToken(&publicNodes{root: root}, root, nodeValue, bootstrapDir)
}

// renewTunnelIdentity issues a new client identity for the tunnel into the
// handover bundle the operator already carries to the node machine.
func renewTunnelIdentity(root, nodeBootstrap string) (entrance.TunnelRenewResult, error) {
	return entrance.RenewTunnelIdentity(&publicNodes{root: root}, root, nodeBootstrap)
}

// runPublicNode runs the `node` command of this gateway's command line, which
// is the lifecycle every gateway shares over what only this shape contributes.
func runPublicNode(parts []string, output io.Writer) error {
	return entrance.RunNode(parts, openPublicNodes, output)
}

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
