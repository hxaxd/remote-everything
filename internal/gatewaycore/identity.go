package gatewaycore

import (
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/secret"
)

// nodeTokenDirectoryName is where a gateway keeps the control token of each node
// it serves. There is one token per node rather than one per gateway, so a node
// machine that leaks what it was given does not hand over the others.
const nodeTokenDirectoryName = "nodes"

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
// under and the control token this node authenticates it with. Everything else a
// gateway owns — its certificates, its tunnel, its other nodes — is not part of
// this. Where the installation id is kept belongs to the entrance, since it is
// part of that entrance's own state; the control token lives with the node it
// belongs to, so the bundle written for one node carries that node's token and
// nothing else.
type Identity struct {
	InstallationID string
	ControlToken   string
}

// NodeTokenPath is where a gateway keeps the control token of one of its nodes.
func NodeTokenPath(gatewayRoot, nodeID string) string {
	return filepath.Join(filepath.Clean(gatewayRoot), nodeTokenDirectoryName, nodeID)
}

// ReadNodeToken returns the control token held for a node.
func ReadNodeToken(gatewayRoot, nodeID string) (string, error) {
	if !validToken.MatchString(nodeID) {
		return "", errors.New("invalid node id")
	}
	contents, err := os.ReadFile(NodeTokenPath(gatewayRoot, nodeID))
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(contents))
	if !validToken.MatchString(token) {
		return "", errors.New("invalid control token")
	}
	return token, nil
}

// EnsureNodeToken returns the control token held for a node, creating one when
// that node has none. It never replaces a token that is already there, so a node
// that is already bound keeps accepting this gateway.
func EnsureNodeToken(gatewayRoot, nodeID string) (string, error) {
	token, err := ReadNodeToken(gatewayRoot, nodeID)
	if err == nil {
		return token, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return ReplaceNodeToken(gatewayRoot, nodeID)
}

// ReplaceNodeToken mints a new control token for a node and writes it where this
// gateway reads it. Replacing one is how a machine whose token leaked is taken out
// of reach again: the token is the whole of what that machine authenticates this
// gateway with, and this is the only thing that writes a new one.
func ReplaceNodeToken(gatewayRoot, nodeID string) (string, error) {
	if !validToken.MatchString(nodeID) {
		return "", errors.New("invalid node id")
	}
	token, err := secret.Hex(32)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(NodeTokenPath(gatewayRoot, nodeID)), 0o700); err != nil {
		return "", err
	}
	if err := atomicfile.Write(NodeTokenPath(gatewayRoot, nodeID), []byte(token+"\n"), 0o600); err != nil {
		return "", err
	}
	return token, nil
}

// RemoveNodeToken forgets the control token of a node this gateway no longer
// serves. A node that is added again is minted a new token rather than handed back
// the one it had, so what a decommissioned machine still holds authenticates
// nothing.
func RemoveNodeToken(gatewayRoot, nodeID string) error {
	if !validToken.MatchString(nodeID) {
		return errors.New("invalid node id")
	}
	if err := os.Remove(NodeTokenPath(gatewayRoot, nodeID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// WriteBundle writes the identity bundle an operator hands to a node. A gateway
// runs wherever it runs, so handing the bundle over is the only way it reaches a
// node: there is no gateway that imports its own binding.
func (identity Identity) WriteBundle(directory string) error {
	return deploymentbootstrap.WriteNodeBundle(directory, identity.InstallationID, identity.ControlToken)
}

// ReplaceBundle writes the same bundle over one that is already there, which is
// what delivering a replaced control token is: the operator is re-handing this
// machine the identity it authenticates with, and only they can tell it so.
func (identity Identity) ReplaceBundle(directory string) error {
	return deploymentbootstrap.ReplaceNodeBundle(directory, identity.InstallationID, identity.ControlToken)
}
