package nodecore

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sync"

	"github.com/hxaxd/remote-everything/internal/backplane/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/infra/atomicfile"
	"github.com/hxaxd/remote-everything/internal/infra/jsonfile"
	"github.com/hxaxd/remote-everything/internal/infra/netaddr"
	"github.com/hxaxd/remote-everything/internal/infra/secret"
	"github.com/hxaxd/remote-everything/internal/node/nodeadapter"
)

var validToken = regexp.MustCompile(`^[a-f0-9]{64}$`)

// GatewayBinding is one gateway as the node knows it: the installation identity
// it is bound by and the control token it authenticates with. Everything else a
// gateway owns — its certificates, its tunnel — stays on the gateway side.
// Each binding keeps its own subdirectory under bindings/.
type GatewayBinding struct {
	InstallationID   string `json:"installation_id"`
	ControlTokenFile string `json:"control_token_file"`
}

type State struct {
	NodeID        string           `json:"node_id"`
	ListenAddress string           `json:"listen_address"`
	Bindings      []GatewayBinding `json:"bindings"`
}

// BindingResult is returned by Initialize and AddBinding.
type BindingResult struct {
	OK             bool   `json:"ok"`
	State          string `json:"state"`
	NodeID         string `json:"node_id"`
	ListenAddress  string `json:"listen_address"`
	InstallationID string `json:"installation_id,omitempty"`
}

func writeBootstrapFile(path string, contents []byte, mode os.FileMode) error {
	existing, err := os.ReadFile(path)
	if err == nil {
		if string(existing) != string(contents) {
			return errors.New("existing binding material does not match bootstrap")
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicfile.Write(path, contents, mode)
}

type Node struct {
	root         string
	appsFile     string
	enabledRoot  string
	logsRoot     string
	stateFile    string
	bindingsRoot string
	platform     Platform
	logMu        sync.Mutex
	adapters     map[string]*nodeadapter.Adapter
	adaptersMu   sync.RWMutex
}

func statePaths(root string) (*Node, error) {
	if !filepath.IsAbs(root) {
		return nil, errors.New("state path must be absolute")
	}
	root = filepath.Clean(root)
	return &Node{
		root:         root,
		appsFile:     filepath.Join(root, "apps.json"),
		enabledRoot:  filepath.Join(root, "enabled"),
		logsRoot:     filepath.Join(root, "logs"),
		stateFile:    filepath.Join(root, "node.json"),
		bindingsRoot: filepath.Join(root, "bindings"),
	}, nil
}

func loadStateFile(path string) (State, error) {
	var state State
	if err := jsonfile.Read(path, &state); err != nil {
		return State{}, err
	}
	if !validToken.MatchString(state.NodeID) || !netaddr.ValidUnicast(state.ListenAddress) {
		return State{}, errors.New("invalid node state")
	}
	seen := map[string]bool{}
	for _, b := range state.Bindings {
		if !validToken.MatchString(b.InstallationID) {
			return State{}, errors.New("invalid binding installation_id")
		}
		if seen[b.InstallationID] {
			return State{}, errors.New("duplicate binding installation_id")
		}
		seen[b.InstallationID] = true
	}
	return state, nil
}

func LoadState(root string) (State, error) {
	node, err := statePaths(root)
	if err != nil {
		return State{}, err
	}
	return node.currentState()
}

// currentState reads node.json on every call. The state file is the single
// source of truth for bindings and listen address, so binding add/remove take
// effect on the running serve without a restart.
func (node *Node) currentState() (State, error) {
	return loadStateFile(node.stateFile)
}

// Initialize creates a new node that listens on listenHost with an allocated
// port. The host is the address a gateway dials, so a node whose gateway runs on
// another machine has to listen on an address that machine can reach; the
// default loopback suits a gateway on the same machine and the tunnel form. No
// bindings are created — use AddBinding for that.
func Initialize(root, listenHost string) (BindingResult, error) {
	node, err := statePaths(root)
	if err != nil {
		return BindingResult{}, err
	}
	if !netaddr.ValidUnicastHost(listenHost) {
		return BindingResult{}, errors.New("invalid listen host")
	}
	if err := os.MkdirAll(node.enabledRoot, 0o700); err != nil {
		return BindingResult{}, err
	}
	if err := os.MkdirAll(node.logsRoot, 0o700); err != nil {
		return BindingResult{}, err
	}

	state, err := loadStateFile(node.stateFile)
	if errors.Is(err, os.ErrNotExist) {
		nodeID, randomErr := secret.Hex(32)
		if randomErr != nil {
			return BindingResult{}, randomErr
		}
		listenAddress, allocateErr := netaddr.Reserve(listenHost, 58627)
		if allocateErr != nil {
			return BindingResult{}, allocateErr
		}
		state = State{NodeID: nodeID, ListenAddress: listenAddress, Bindings: []GatewayBinding{}}
		if err := jsonfile.Write(node.stateFile, state, 0o600); err != nil {
			return BindingResult{}, err
		}
	} else if err != nil {
		return BindingResult{}, fmt.Errorf("load node state: %w", err)
	} else if host, _, splitErr := net.SplitHostPort(state.ListenAddress); splitErr != nil {
		return BindingResult{}, splitErr
	} else if host != listenHost {
		return BindingResult{}, fmt.Errorf("node already listens on %s; ports repair --listen moves it", host)
	}

	if _, err := os.Stat(node.appsFile); errors.Is(err, os.ErrNotExist) {
		if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{}}); err != nil {
			return BindingResult{}, err
		}
	} else if err != nil {
		return BindingResult{}, err
	} else if _, err := node.loadRegistry(); err != nil {
		return BindingResult{}, err
	}

	return BindingResult{
		OK:            true,
		State:         node.root,
		NodeID:        state.NodeID,
		ListenAddress: state.ListenAddress,
	}, nil
}

// AddBinding reads an identity bundle and registers a gateway binding.
// Re-adding the same installation is idempotent: writeBootstrapFile rejects an
// existing token file that differs from the bundle, and an identical token
// leaves both the file and the state entry unchanged.
func AddBinding(root, bootstrapRoot string) (BindingResult, error) {
	bundle, err := deploymentbootstrap.ReadNodeBundle(bootstrapRoot)
	if err != nil {
		return BindingResult{}, err
	}
	node, err := statePaths(root)
	if err != nil {
		return BindingResult{}, err
	}
	state, err := loadStateFile(node.stateFile)
	if err != nil {
		return BindingResult{}, err
	}
	bindingDir := filepath.Join(node.bindingsRoot, bundle.InstallationID)
	if err := os.MkdirAll(bindingDir, 0o700); err != nil {
		return BindingResult{}, err
	}
	binding := GatewayBinding{
		InstallationID:   bundle.InstallationID,
		ControlTokenFile: filepath.Join(bindingDir, deploymentbootstrap.ControlTokenName),
	}
	if err := writeBootstrapFile(binding.ControlTokenFile, []byte(bundle.ControlToken+"\n"), 0o600); err != nil {
		return BindingResult{}, err
	}
	found := false
	for i, b := range state.Bindings {
		if b.InstallationID == bundle.InstallationID {
			state.Bindings[i] = binding
			found = true
			break
		}
	}
	if !found {
		state.Bindings = append(state.Bindings, binding)
	}
	if err := jsonfile.Write(node.stateFile, state, 0o600); err != nil {
		return BindingResult{}, err
	}
	return BindingResult{
		OK:             true,
		State:          node.root,
		NodeID:         state.NodeID,
		ListenAddress:  state.ListenAddress,
		InstallationID: bundle.InstallationID,
	}, nil
}

// RemoveBinding removes a gateway binding and deletes its materials.
// Idempotent — returns nil if the binding does not exist.
func RemoveBinding(root, installationID string) error {
	node, err := statePaths(root)
	if err != nil {
		return err
	}
	state, err := loadStateFile(node.stateFile)
	if err != nil {
		return err
	}
	filtered := state.Bindings[:0]
	removed := false
	for _, b := range state.Bindings {
		if b.InstallationID == installationID {
			removed = true
			continue
		}
		filtered = append(filtered, b)
	}
	if !removed {
		return nil
	}
	state.Bindings = filtered
	if err := jsonfile.Write(node.stateFile, state, 0o600); err != nil {
		return err
	}
	bindingDir := filepath.Join(node.bindingsRoot, installationID)
	return os.RemoveAll(bindingDir)
}

func Open(root string, platform Platform) (*Node, error) {
	node, err := statePaths(root)
	if err != nil {
		return nil, err
	}
	if _, err := node.currentState(); err != nil {
		return nil, err
	}
	node.platform = platform
	node.adapters = map[string]*nodeadapter.Adapter{}
	if _, err := node.loadRegistry(); err != nil {
		return nil, err
	}
	return node, nil
}

// RepairPorts reallocates the address the node listens on, keeping its identity.
// An empty listenHost keeps the host the node already listens on, which is what
// its gateways are configured with; a host moves the node to another address,
// which is how a node whose network address changed is put back in reach without
// minting a new identity.
func RepairPorts(root, listenHost string) (BindingResult, error) {
	node, err := statePaths(root)
	if err != nil {
		return BindingResult{}, err
	}
	state, err := loadStateFile(node.stateFile)
	if err != nil {
		return BindingResult{}, err
	}
	reserved := make(map[string]bool)
	var registry Registry
	if err := jsonfile.Read(node.appsFile, &registry); err != nil && !os.IsNotExist(err) {
		return BindingResult{}, err
	}
	for _, app := range registry.Apps {
		if address, err := proxyAddress(app.ProxyURL); err == nil {
			reserved[address] = true
		}
	}
	if listenHost == "" {
		if listenHost, _, err = net.SplitHostPort(state.ListenAddress); err != nil {
			return BindingResult{}, err
		}
	} else if !netaddr.ValidUnicastHost(listenHost) {
		return BindingResult{}, errors.New("invalid listen host")
	}
	chosen := ""
	preferred := 58627
	for attempts := 0; attempts < 3 && chosen == ""; attempts++ {
		candidate, err := netaddr.Reserve(listenHost, preferred)
		if err != nil {
			return BindingResult{}, err
		}
		if !reserved[candidate] {
			chosen = candidate
		}
		preferred = 0
	}
	if chosen == "" {
		return BindingResult{}, errors.New("no port available outside registered applications")
	}
	state.ListenAddress = chosen
	if err := jsonfile.Write(node.stateFile, state, 0o600); err != nil {
		return BindingResult{}, err
	}
	return BindingResult{OK: true, State: node.root, NodeID: state.NodeID, ListenAddress: state.ListenAddress}, nil
}
