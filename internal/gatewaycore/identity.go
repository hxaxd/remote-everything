package gatewaycore

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/nodecore"
)

const controlTokenName = "control-token"

// NewServer returns the HTTP server a gateway serves one of its listeners on.
// A gateway listener carries long-lived WebSocket connections to applications,
// so it keeps an idle timeout, and the read header timeout bounds how long a
// client may take to send its request line.
func NewServer(address string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr: address, Handler: handler,
		ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second,
	}
}

// Identity is what a node knows a gateway by: the installation id it is bound
// under and the control token it authenticates with. Everything else a gateway
// owns — its certificates, its tunnel — is not part of this. Where the
// installation id is kept belongs to the entrance, since it is part of that
// entrance's own state; the control token lives in the gateway root so every
// entrance and any node-side tooling find it the same way.
type Identity struct {
	InstallationID string
	ControlToken   string
}

// ControlTokenPath is where a gateway keeps the control token of its identity.
func ControlTokenPath(gatewayRoot string) string {
	return filepath.Join(gatewayRoot, controlTokenName)
}

// NewSecret returns a new 64-hex secret for a gateway to identify or authenticate
// itself with.
func NewSecret() (string, error) {
	value := make([]byte, 32)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

// ReadControlToken returns the control token held in gatewayRoot.
func ReadControlToken(gatewayRoot string) (string, error) {
	contents, err := os.ReadFile(ControlTokenPath(gatewayRoot))
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(contents))
	if !validToken.MatchString(token) {
		return "", errors.New("invalid control token")
	}
	return token, nil
}

// EnsureControlToken returns the control token held in gatewayRoot, creating one
// when the root has none. It never replaces a token that is already there, so a
// node that is already bound keeps accepting this gateway.
func EnsureControlToken(gatewayRoot string) (string, error) {
	token, err := ReadControlToken(gatewayRoot)
	if err == nil {
		return token, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	token, err = NewSecret()
	if err != nil {
		return "", err
	}
	if err := atomicfile.Write(ControlTokenPath(gatewayRoot), []byte(token+"\n"), 0o600); err != nil {
		return "", err
	}
	return token, nil
}

// WriteBundle writes the identity bundle an operator hands to a node.
func (identity Identity) WriteBundle(directory string) error {
	return deploymentbootstrap.WriteNodeBundle(directory, identity.InstallationID, identity.ControlToken)
}

// Bind hands this identity to the node rooted at nodeRoot.
func (identity Identity) Bind(nodeRoot string) error {
	directory, err := os.MkdirTemp("", "remote-everything-bootstrap-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(directory)
	if err := identity.WriteBundle(directory); err != nil {
		return err
	}
	_, err = nodecore.AddBinding(nodeRoot, directory)
	return err
}
