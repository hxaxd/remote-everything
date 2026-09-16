package nodecore

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/nodeadapter"
)

var validToken = regexp.MustCompile(`^[a-f0-9]{64}$`)

// GatewayBinding represents one gateway-to-node relationship.
// All context for a binding lives in its own subdirectory under bindings/.
type GatewayBinding struct {
	InstallationID   string `json:"installation_id"`
	ControlTokenFile string `json:"control_token_file"`
	FRPSTokenFile    string `json:"frps_token_file,omitempty"`
	CACertFile       string `json:"ca_cert_file,omitempty"`
	ClientCertFile   string `json:"client_cert_file,omitempty"`
	ClientKeyFile    string `json:"client_key_file,omitempty"`
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
			return errors.New("existing tunnel material does not match bootstrap")
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

func randomHex(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func validLoopbackAddress(address string) bool {
	host, portText, err := net.SplitHostPort(address)
	if err != nil || host != "127.0.0.1" {
		return false
	}
	port, err := strconv.Atoi(portText)
	return err == nil && port >= 1024 && port <= 65535
}

func allocateLoopback(preferred int) (string, error) {
	addresses := []string{net.JoinHostPort("127.0.0.1", strconv.Itoa(preferred)), "127.0.0.1:0"}
	for _, address := range addresses {
		listener, err := net.Listen("tcp4", address)
		if err != nil {
			continue
		}
		allocated := listener.Addr().String()
		if closeErr := listener.Close(); closeErr != nil {
			return "", closeErr
		}
		if validLoopbackAddress(allocated) {
			return allocated, nil
		}
	}
	return "", errors.New("no loopback port available")
}

func decodeSingleJSON(path string, output any) error {
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

func loadStateFile(path string) (State, error) {
	var state State
	if err := decodeSingleJSON(path, &state); err != nil {
		return State{}, err
	}
	if !validToken.MatchString(state.NodeID) || !validLoopbackAddress(state.ListenAddress) {
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

func saveState(path string, state State) error {
	contents, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return atomicfile.Write(path, append(contents, '\n'), 0o600)
}

// Initialize creates a new node with a random NodeID and allocated loopback
// address. No bindings are created — use AddBinding for that.
func Initialize(root string) (BindingResult, error) {
	node, err := statePaths(root)
	if err != nil {
		return BindingResult{}, err
	}
	if err := os.MkdirAll(node.enabledRoot, 0o700); err != nil {
		return BindingResult{}, err
	}
	if err := os.MkdirAll(node.logsRoot, 0o700); err != nil {
		return BindingResult{}, err
	}

	state, err := loadStateFile(node.stateFile)
	if errors.Is(err, os.ErrNotExist) {
		nodeID, randomErr := randomHex(32)
		if randomErr != nil {
			return BindingResult{}, randomErr
		}
		listenAddress, allocateErr := allocateLoopback(58627)
		if allocateErr != nil {
			return BindingResult{}, allocateErr
		}
		state = State{NodeID: nodeID, ListenAddress: listenAddress, Bindings: []GatewayBinding{}}
		if err := saveState(node.stateFile, state); err != nil {
			return BindingResult{}, err
		}
	} else if err != nil {
		return BindingResult{}, fmt.Errorf("load node state: %w", err)
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

// AddBinding reads a bootstrap bundle and registers a gateway binding.
// Re-adding the same installation is idempotent: writeBootstrapFile rejects
// existing materials that differ from the bundle, and identical materials
// leave every file and the state entry unchanged.
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
	fingerprint, err := deploymentbootstrap.Fingerprint(bundle.ClientCert)
	if err != nil {
		return BindingResult{}, err
	}
	binding := GatewayBinding{
		InstallationID:   bundle.InstallationID,
		ControlTokenFile: filepath.Join(bindingDir, "control-token"),
		FRPSTokenFile:    filepath.Join(bindingDir, deploymentbootstrap.FRPSTokenName),
		CACertFile:       filepath.Join(bindingDir, deploymentbootstrap.TunnelCACertName),
		ClientCertFile:   filepath.Join(bindingDir, "tunnel-client-"+fingerprint+".crt.pem"),
		ClientKeyFile:    filepath.Join(bindingDir, "tunnel-client-"+fingerprint+".key.pem"),
	}
	files := []struct {
		path     string
		contents []byte
		mode     os.FileMode
	}{
		{binding.ControlTokenFile, []byte(bundle.ControlToken + "\n"), 0o600},
		{binding.FRPSTokenFile, []byte(bundle.FRPSToken + "\n"), 0o600},
		{binding.CACertFile, bundle.CACertificate, 0o644},
		{binding.ClientCertFile, bundle.ClientCert, 0o644},
		{binding.ClientKeyFile, bundle.ClientKey, 0o600},
	}
	for _, f := range files {
		if err := writeBootstrapFile(f.path, f.contents, f.mode); err != nil {
			return BindingResult{}, err
		}
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
	if err := saveState(node.stateFile, state); err != nil {
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
	if err := saveState(node.stateFile, state); err != nil {
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

func RepairPorts(root string) (BindingResult, error) {
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
	if err := decodeSingleJSON(node.appsFile, &registry); err != nil && !os.IsNotExist(err) {
		return BindingResult{}, err
	}
	for _, app := range registry.Apps {
		if address, err := proxyAddress(app.ProxyURL); err == nil {
			reserved[address] = true
		}
	}
	chosen := ""
	preferred := 58627
	for attempts := 0; attempts < 3 && chosen == ""; attempts++ {
		candidate, err := allocateLoopback(preferred)
		if err != nil {
			return BindingResult{}, err
		}
		if !reserved[candidate] {
			chosen = candidate
		}
		preferred = 0
	}
	if chosen == "" {
		return BindingResult{}, errors.New("no loopback port available outside registered applications")
	}
	state.ListenAddress = chosen
	if err := saveState(node.stateFile, state); err != nil {
		return BindingResult{}, err
	}
	return BindingResult{OK: true, State: node.root, NodeID: state.NodeID, ListenAddress: state.ListenAddress}, nil
}
