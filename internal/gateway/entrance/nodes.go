// The node lifecycle of a gateway: what adding a node, removing one, renewing
// its token and renewing its tunnel identity mean, written once and run by
// both shapes. Recording and delivering an identity is the same work whoever
// the gateway is; what a shape contributes is where it places the node it is
// given, and what it takes with a node it loses — the rest it is told here.
package entrance

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/hxaxd/remote-everything/internal/backplane/tunnelbootstrap"
	"github.com/hxaxd/remote-everything/internal/gateway/devicecore"
	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
)

// NodeResult is what adding a node reports: where the gateway recorded it,
// what it was handed, and that serving it waits for a restart.
type NodeResult struct {
	OK                      bool   `json:"ok"`
	State                   string `json:"state"`
	NodeID                  string `json:"node_id"`
	NodeName                string `json:"node_name"`
	NodeAddress             string `json:"node_address"`
	NodeLink                string `json:"node_link"`
	NodeBootstrap           string `json:"node_bootstrap"`
	TunnelMaterialDir       string `json:"tunnel_material_directory,omitempty"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint,omitempty"`
	RestartRequired         bool   `json:"restart_required"`
}

// NodeRemoveResult is what removing a node reports, including the devices it
// was taken out of.
type NodeRemoveResult struct {
	OK              bool     `json:"ok"`
	State           string   `json:"state"`
	NodeID          string   `json:"node_id"`
	NodeName        string   `json:"node_name"`
	NodeAddress     string   `json:"node_address"`
	Devices         []string `json:"devices"`
	RestartRequired bool     `json:"restart_required"`
}

// TokenRenewResult is what replacing a node's control token reports.
type TokenRenewResult struct {
	OK              bool   `json:"ok"`
	State           string `json:"state"`
	NodeID          string `json:"node_id"`
	NodeName        string `json:"node_name"`
	NodeAddress     string `json:"node_address"`
	NodeBootstrap   string `json:"node_bootstrap"`
	RestartRequired bool   `json:"restart_required"`
}

// TunnelRenewResult is what issuing a fresh tunnel identity reports.
type TunnelRenewResult struct {
	OK                      bool   `json:"ok"`
	InstallationID          string `json:"installation_id"`
	NodeBootstrap           string `json:"node_bootstrap"`
	TunnelCAFile            string `json:"tunnel_ca_file"`
	TunnelMaterialDir       string `json:"tunnel_material_directory"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	TunnelIssuerDN          string `json:"tunnel_issuer_dn"`
}

// Placement is where a node being added is reached, and what its handover
// bundle carries beside the identity.
type Placement struct {
	// Address is where this gateway will reach the node.
	Address string
	// Tunnel, when set, is the gateway's tunnel material: the node arrives
	// over this gateway's own tunnel, and its bundle also carries the client
	// identity and token the agent on its machine runs on.
	Tunnel *tunnelbootstrap.GatewayMaterial
}

// NodeShape is what a gateway shape contributes to the node lifecycle: how its
// state is read and written, where a node being added is placed, and what a
// removed node takes from it that only it knows. The lifecycle's part — the
// record, the delivery, the order things are written in — is not the shape's.
type NodeShape interface {
	// State reads this shape's state as the gateway state the lifecycle edits.
	State() (gatewaycore.State, error)
	// Save writes the gateway state given in it back into this shape's own
	// state, with whatever else the shape keeps around it.
	Save(gatewaycore.State) error
	// Trust opens the device trust of this gateway, for the remove that takes
	// the node out of every device it was granted. It is called while the node
	// is still served, because it is the gateway of that moment that answers
	// for it.
	Trust() (*devicecore.Trust, error)
	// PlaceNode decides where a node being added is reached and what its
	// bundle carries, and returns the state the node is to be recorded into —
	// placing a node can be what gives the state something to record, such as
	// the tunnel listener the node arrives through. It runs before the
	// identity is delivered, so a shape that cannot place the node stops the
	// add before anything is written.
	PlaceNode(nodeID, address string) (gatewaycore.State, Placement, error)
	// TookNodeAway is the shape's part of a remove: what only it knows to take
	// with the node. What the lifecycle takes regardless — the record, the
	// devices' grants, the control token — is not the shape's to repeat.
	TookNodeAway(nodeID string) error
	// TunnelMaterial is this gateway's tunnel material, for the renew that
	// hands a node's agent a fresh identity. A shape with no tunnel has none
	// to renew, and says so.
	TunnelMaterial() (tunnelbootstrap.GatewayMaterial, error)
}

// AddNode records one more node this gateway serves and hands its machine the
// identity bundle it binds the gateway with. The address is the shape's to
// state, and it is stated before anything is written: a node delivered and
// not recorded is one nobody was told about, while a node recorded and not
// delivered is one the gateway cannot reach. The state is saved last, so an
// add that fails partway leaves the state as it was and one thing to repeat.
func AddNode(shape NodeShape, root, name, nodeID, address, link, bootstrapDir string) (NodeResult, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return NodeResult{}, errors.New("node bootstrap path must be absolute")
	}
	nodeID = strings.ToLower(strings.TrimSpace(nodeID))
	name = strings.TrimSpace(name)
	link = strings.ToLower(strings.TrimSpace(link))
	if !gatewaycore.ValidNodeName(name) {
		return NodeResult{}, errors.New("invalid node name")
	}
	if link != "" && !gatewaycore.ValidNodeLink(link) {
		return NodeResult{}, errors.New("invalid node link: expected local or tunnel")
	}
	if _, err := shape.State(); err != nil {
		return NodeResult{}, err
	}
	state, placement, err := shape.PlaceNode(nodeID, address)
	if err != nil {
		return NodeResult{}, err
	}
	// What the link is called follows the operator's word when they give one, and
	// this gateway's own answer when they do not: a node this gateway carries over
	// its own tunnel is a tunnel, and one it dials where it stands is local. Only
	// the operator knows what a link costs the person using it, so their word wins.
	if link == "" {
		if placement.Tunnel != nil {
			link = gatewaycore.NodeLinkTunnel
		} else {
			link = gatewaycore.NodeLinkLocal
		}
	}
	node := gatewaycore.Node{ID: nodeID, Name: name, Address: placement.Address, Link: link}
	added, err := gatewaycore.DeliverNode(root, state, node, bootstrapDir)
	if err != nil {
		return NodeResult{}, err
	}
	tunnelDir, tunnelFingerprint := "", ""
	if placement.Tunnel != nil {
		tunnel, err := tunnelbootstrap.EnsureTunnelMaterial(bootstrapDir, *placement.Tunnel)
		if err != nil {
			return NodeResult{}, err
		}
		tunnelDir, tunnelFingerprint = tunnel.Directory, tunnel.Fingerprint
	}
	if err := shape.Save(added); err != nil {
		return NodeResult{}, err
	}
	return NodeResult{
		OK: true, State: root, NodeID: nodeID, NodeName: name, NodeAddress: placement.Address, NodeLink: link,
		NodeBootstrap:           filepath.Clean(bootstrapDir),
		TunnelMaterialDir:       tunnelDir,
		TunnelClientFingerprint: tunnelFingerprint,
		RestartRequired:         true,
	}, nil
}

// RemoveNode takes a node out of this gateway: it stops serving it, it stops
// reaching it, and nothing a device holds says it may reach it any more. The
// trust is opened while the node is still served; after that the state goes
// first — a node the gateway no longer serves is unrouted at once, and what is
// left behind by a failure, a device's list or a token file, reaches nothing.
func RemoveNode(shape NodeShape, root, nodeValue string) (NodeRemoveResult, error) {
	state, err := shape.State()
	if err != nil {
		return NodeRemoveResult{}, err
	}
	node, err := gatewaycore.ResolveNode(state.Nodes, nodeValue)
	if err != nil {
		return NodeRemoveResult{}, err
	}
	trust, err := shape.Trust()
	if err != nil {
		return NodeRemoveResult{}, err
	}
	reduced, err := state.RemoveNode(node.ID)
	if err != nil {
		return NodeRemoveResult{}, err
	}
	if err := shape.TookNodeAway(node.ID); err != nil {
		return NodeRemoveResult{}, err
	}
	if err := shape.Save(reduced); err != nil {
		return NodeRemoveResult{}, err
	}
	devices, err := trust.ForgetNode(node.ID)
	if err != nil {
		return NodeRemoveResult{}, err
	}
	if err := gatewaycore.RemoveNodeToken(root, node.ID); err != nil {
		return NodeRemoveResult{}, fmt.Errorf("the node was removed, but its control token could not be deleted: %w", err)
	}
	return NodeRemoveResult{
		OK: true, State: root, NodeID: node.ID, NodeName: node.Name, NodeAddress: node.Address,
		Devices: devices, RestartRequired: true,
	}, nil
}

// RenewNodeToken replaces the control token of a node this gateway serves and
// hands that machine the bundle carrying it. Which node it is, and where it
// is, do not change: this is for the machine that was given a token and should
// not have it any more. The state does not change — the node is the same node
// — so it is not written again; what changes is the token, and the bundle that
// carries it.
func RenewNodeToken(shape NodeShape, root, nodeValue, bootstrapDir string) (TokenRenewResult, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return TokenRenewResult{}, errors.New("node bootstrap path must be absolute")
	}
	state, err := shape.State()
	if err != nil {
		return TokenRenewResult{}, err
	}
	node, err := gatewaycore.ResolveNode(state.Nodes, nodeValue)
	if err != nil {
		return TokenRenewResult{}, err
	}
	if _, err := gatewaycore.DeliverRotatedNode(root, state, node, bootstrapDir); err != nil {
		return TokenRenewResult{}, err
	}
	return TokenRenewResult{
		OK: true, State: root, NodeID: node.ID, NodeName: node.Name, NodeAddress: node.Address,
		NodeBootstrap: filepath.Clean(bootstrapDir), RestartRequired: true,
	}, nil
}

// RenewTunnelIdentity issues a new client identity for the tunnel into the
// handover bundle the operator already carries to the node machine. The node
// takes no part in it: neither the identity the gateway is bound by nor the
// tunnel CA changes, so only the tunnel agent has to be pointed at the newly
// delivered files and restarted.
func RenewTunnelIdentity(shape NodeShape, root, nodeBootstrap string) (TunnelRenewResult, error) {
	if !filepath.IsAbs(nodeBootstrap) {
		return TunnelRenewResult{}, errors.New("node bootstrap path must be absolute")
	}
	state, err := shape.State()
	if err != nil {
		return TunnelRenewResult{}, err
	}
	material, err := shape.TunnelMaterial()
	if err != nil {
		return TunnelRenewResult{}, err
	}
	tunnel, err := tunnelbootstrap.RenewTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return TunnelRenewResult{}, err
	}
	return TunnelRenewResult{
		OK: true, InstallationID: state.InstallationID,
		NodeBootstrap: filepath.Clean(nodeBootstrap), TunnelCAFile: material.CACertFile,
		TunnelIssuerDN:    material.CACertificate.Subject.String(),
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
	}, nil
}

// RunNode runs the `node` command of a gateway's command line, after the word
// that names the command: adding, listing, removing a node and renewing its
// token are the same work on every shape — the arguments they take, the order
// they write things in, the JSON they answer with — over the few places a
// shape differs, which it fills in.
func RunNode(args []string, open func(root string) (NodeShape, error), output io.Writer) error {
	if len(args) == 0 {
		return errors.New("missing node action")
	}
	if len(args) >= 2 && args[0] == "token" && args[1] == "renew" {
		return runNodeTokenRenew(args[2:], open, output)
	}
	flags := flag.NewFlagSet("node "+args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	name := flags.String("name", "", "")
	nodeID := flags.String("node-id", "", "")
	node := flags.String("node", "", "")
	nodeAddress := flags.String("node-address", "", "")
	nodeLink := flags.String("link", "", "")
	bootstrapDir := flags.String("node-bootstrap", "", "")
	if flags.Parse(args[1:]) != nil || flags.NArg() != 0 {
		return errors.New("invalid node arguments")
	}
	switch args[0] {
	case "add":
		if *name == "" || *nodeID == "" || *bootstrapDir == "" {
			return errors.New("invalid node add arguments")
		}
		shape, err := open(*state)
		if err != nil {
			return err
		}
		result, err := AddNode(shape, *state, *name, *nodeID, *nodeAddress, *nodeLink, *bootstrapDir)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(result)
	case "list":
		if *name != "" || *nodeID != "" || *node != "" || *nodeAddress != "" || *nodeLink != "" || *bootstrapDir != "" {
			return errors.New("invalid node list arguments")
		}
		shape, err := open(*state)
		if err != nil {
			return err
		}
		state, err := shape.State()
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(state.Nodes)
	case "remove":
		if *node == "" || *name != "" || *nodeID != "" || *nodeAddress != "" || *bootstrapDir != "" {
			return errors.New("invalid node remove arguments")
		}
		shape, err := open(*state)
		if err != nil {
			return err
		}
		result, err := RemoveNode(shape, *state, *node)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(result)
	default:
		return errors.New("unknown node action")
	}
}

func runNodeTokenRenew(args []string, open func(root string) (NodeShape, error), output io.Writer) error {
	flags := flag.NewFlagSet("node token renew", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	node := flags.String("node", "", "")
	bootstrapDir := flags.String("node-bootstrap", "", "")
	if flags.Parse(args) != nil || flags.NArg() != 0 || *node == "" || *bootstrapDir == "" {
		return errors.New("invalid node token renew arguments")
	}
	shape, err := open(*state)
	if err != nil {
		return err
	}
	result, err := RenewNodeToken(shape, *state, *node, *bootstrapDir)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

// RunTunnelRenew runs the `tunnel renew` command of a gateway's command line:
// pointing a node's tunnel agent at a fresh identity is the same work on every
// shape that has a tunnel.
func RunTunnelRenew(args []string, open func(root string) (NodeShape, error), output io.Writer) error {
	flags := flag.NewFlagSet("tunnel renew", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	nodeBootstrap := flags.String("node-bootstrap", "", "")
	if flags.Parse(args) != nil || flags.NArg() != 0 || *state == "" || *nodeBootstrap == "" {
		return errors.New("invalid tunnel renew arguments")
	}
	shape, err := open(*state)
	if err != nil {
		return err
	}
	result, err := RenewTunnelIdentity(shape, *state, *nodeBootstrap)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
