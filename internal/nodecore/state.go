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
	"strings"
	"sync"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
)

const stateSchema = 1

var validToken = regexp.MustCompile(`^[a-f0-9]{64}$`)

type State struct {
	Schema         int    `json:"schema"`
	InstallationID string `json:"installation_id"`
	ListenAddress  string `json:"listen_address"`
}

type InitResult struct {
	OK               bool   `json:"ok"`
	State            string `json:"state"`
	InstallationID   string `json:"installation_id"`
	ListenAddress    string `json:"listen_address"`
	ControlTokenFile string `json:"control_token_file"`
	FRPSTokenFile    string `json:"frps_token_file,omitempty"`
	TunnelCACertFile string `json:"tunnel_ca_certificate_file,omitempty"`
	TunnelClientCert string `json:"tunnel_client_certificate_file,omitempty"`
	TunnelClientKey  string `json:"tunnel_client_key_file,omitempty"`
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

func installNodeBundle(root string, bundle deploymentbootstrap.NodeBundle) (InitResult, error) {
	tunnelRoot := filepath.Join(root, "tunnel")
	if err := os.MkdirAll(tunnelRoot, 0o700); err != nil {
		return InitResult{}, err
	}
	fingerprint, err := deploymentbootstrap.Fingerprint(bundle.ClientCert)
	if err != nil {
		return InitResult{}, err
	}
	result := InitResult{
		FRPSTokenFile:    filepath.Join(tunnelRoot, deploymentbootstrap.FRPSTokenName),
		TunnelCACertFile: filepath.Join(tunnelRoot, deploymentbootstrap.TunnelCACertName),
		TunnelClientCert: filepath.Join(tunnelRoot, "tunnel-client-"+fingerprint+".crt.pem"),
		TunnelClientKey:  filepath.Join(tunnelRoot, "tunnel-client-"+fingerprint+".key.pem"),
	}
	immutableFiles := []struct {
		path     string
		contents []byte
		mode     os.FileMode
	}{
		{result.FRPSTokenFile, []byte(bundle.FRPSToken + "\n"), 0o600},
		{result.TunnelCACertFile, bundle.CACertificate, 0o644},
	}
	for _, file := range immutableFiles {
		if err := writeBootstrapFile(file.path, file.contents, file.mode); err != nil {
			return InitResult{}, err
		}
	}
	if err := writeBootstrapFile(result.TunnelClientKey, bundle.ClientKey, 0o600); err != nil {
		return InitResult{}, err
	}
	if err := writeBootstrapFile(result.TunnelClientCert, bundle.ClientCert, 0o644); err != nil {
		return InitResult{}, err
	}
	return result, nil
}

type Node struct {
	root             string
	appsFile         string
	enabledRoot      string
	logsRoot         string
	controlTokenFile string
	stateFile        string
	state            State
	platform         Platform
	logMu            sync.Mutex
}

func statePaths(root string) (*Node, error) {
	if !filepath.IsAbs(root) {
		return nil, errors.New("state path must be absolute")
	}
	root = filepath.Clean(root)
	return &Node{
		root:             root,
		appsFile:         filepath.Join(root, "apps.json"),
		enabledRoot:      filepath.Join(root, "enabled"),
		logsRoot:         filepath.Join(root, "logs"),
		controlTokenFile: filepath.Join(root, "control-token"),
		stateFile:        filepath.Join(root, "node.json"),
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
	if state.Schema != stateSchema || !validToken.MatchString(state.InstallationID) || !validLoopbackAddress(state.ListenAddress) {
		return State{}, errors.New("invalid node state")
	}
	return state, nil
}

func LoadState(root string) (State, error) {
	node, err := statePaths(root)
	if err != nil {
		return State{}, err
	}
	return loadStateFile(node.stateFile)
}

func readRequestedToken(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	if !filepath.IsAbs(path) {
		return "", errors.New("control token file must be absolute")
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(contents))
	if !validToken.MatchString(token) {
		return "", errors.New("invalid control token")
	}
	return token, nil
}

func ensureToken(path, requested string) error {
	contents, err := os.ReadFile(path)
	if err == nil {
		existing := strings.TrimSpace(string(contents))
		if !validToken.MatchString(existing) || (requested != "" && requested != existing) {
			return errors.New("existing control token does not match")
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if requested == "" {
		requested, err = randomHex(32)
		if err != nil {
			return err
		}
	}
	return atomicfile.Write(path, []byte(requested+"\n"), 0o600)
}

func Initialize(root, tokenSource string) (InitResult, error) {
	requestedToken, err := readRequestedToken(tokenSource)
	if err != nil {
		return InitResult{}, err
	}
	return initialize(root, requestedToken, "", nil)
}

func InitializeFromBootstrap(root, bootstrapRoot string) (InitResult, error) {
	bundle, err := deploymentbootstrap.ReadNodeBundle(bootstrapRoot)
	if err != nil {
		return InitResult{}, err
	}
	return initialize(root, bundle.ControlToken, bundle.InstallationID, &bundle)
}

func initialize(root, requestedToken, requestedInstallationID string, bundle *deploymentbootstrap.NodeBundle) (InitResult, error) {
	node, err := statePaths(root)
	if err != nil {
		return InitResult{}, err
	}
	if err := os.MkdirAll(node.enabledRoot, 0o700); err != nil {
		return InitResult{}, err
	}
	if err := os.MkdirAll(node.logsRoot, 0o700); err != nil {
		return InitResult{}, err
	}

	state, err := loadStateFile(node.stateFile)
	if errors.Is(err, os.ErrNotExist) {
		installationID := requestedInstallationID
		if installationID == "" {
			var randomErr error
			installationID, randomErr = randomHex(32)
			if randomErr != nil {
				return InitResult{}, randomErr
			}
		}
		listenAddress, allocateErr := allocateLoopback(58627)
		if allocateErr != nil {
			return InitResult{}, allocateErr
		}
		state = State{Schema: stateSchema, InstallationID: installationID, ListenAddress: listenAddress}
	} else if err != nil {
		return InitResult{}, fmt.Errorf("load node state: %w", err)
	}
	if requestedInstallationID != "" && state.InstallationID != requestedInstallationID {
		return InitResult{}, errors.New("existing node installation does not match bootstrap")
	}
	if err := ensureToken(node.controlTokenFile, requestedToken); err != nil {
		return InitResult{}, err
	}
	node.state = state
	if _, err := os.Stat(node.appsFile); errors.Is(err, os.ErrNotExist) {
		if err := node.saveRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{}}); err != nil {
			return InitResult{}, err
		}
	} else if err != nil {
		return InitResult{}, err
	} else if _, err := node.loadRegistry(); err != nil {
		return InitResult{}, err
	}
	if _, err := os.Stat(node.stateFile); errors.Is(err, os.ErrNotExist) {
		contents, marshalErr := json.Marshal(state)
		if marshalErr != nil {
			return InitResult{}, marshalErr
		}
		if err := atomicfile.Write(node.stateFile, append(contents, '\n'), 0o600); err != nil {
			return InitResult{}, err
		}
	} else if err != nil {
		return InitResult{}, err
	}
	result := InitResult{
		OK:               true,
		State:            node.root,
		InstallationID:   state.InstallationID,
		ListenAddress:    state.ListenAddress,
		ControlTokenFile: node.controlTokenFile,
	}
	if bundle != nil {
		installed, err := installNodeBundle(node.root, *bundle)
		if err != nil {
			return InitResult{}, err
		}
		result.FRPSTokenFile = installed.FRPSTokenFile
		result.TunnelCACertFile = installed.TunnelCACertFile
		result.TunnelClientCert = installed.TunnelClientCert
		result.TunnelClientKey = installed.TunnelClientKey
	}
	return result, nil
}

func Open(root string, platform Platform) (*Node, error) {
	node, err := statePaths(root)
	if err != nil {
		return nil, err
	}
	state, err := loadStateFile(node.stateFile)
	if err != nil {
		return nil, err
	}
	node.state = state
	node.platform = platform
	if _, err := node.loadRegistry(); err != nil {
		return nil, err
	}
	return node, nil
}

func RepairPorts(root string) (InitResult, error) {
	node, err := statePaths(root)
	if err != nil {
		return InitResult{}, err
	}
	state, err := loadStateFile(node.stateFile)
	if err != nil {
		return InitResult{}, err
	}
	reserved := make(map[string]bool)
	var registry Registry
	if err := decodeSingleJSON(node.appsFile, &registry); err != nil && !os.IsNotExist(err) {
		return InitResult{}, err
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
			return InitResult{}, err
		}
		if !reserved[candidate] {
			chosen = candidate
		}
		preferred = 0
	}
	if chosen == "" {
		return InitResult{}, errors.New("no loopback port available outside registered applications")
	}
	state.ListenAddress = chosen
	contents, err := json.Marshal(state)
	if err != nil {
		return InitResult{}, err
	}
	if err := atomicfile.Write(node.stateFile, append(contents, '\n'), 0o600); err != nil {
		return InitResult{}, err
	}
	return InitResult{OK: true, State: node.root, InstallationID: state.InstallationID, ListenAddress: state.ListenAddress, ControlTokenFile: node.controlTokenFile}, nil
}
