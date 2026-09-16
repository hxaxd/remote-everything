// Package entrance is what a gateway shape is: the state it recorded, the trust
// it admits devices with, and the surfaces it answers clients on.
//
// There are two shapes and one protocol. What they own differently is where TLS
// ends — a LAN entrance serves its own certificate and verifies the device
// certificates it issued, while a public entrance stands behind the 443 entrance
// that does both for it — and what its init creates besides the node's handover
// bundle: an entrance certificate against tunnel material. Everything a client
// can observe is the same, so everything a client can observe is driven and
// tested through this contract rather than answered twice.
package entrance

import (
	"errors"
	"net/http"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

// Gateway is one shape of a gateway.
type Gateway interface {
	// State is what this gateway recorded about itself: the identity a node
	// binds it by, the origin its clients dial, and the listeners it serves.
	State() gatewaycore.State
	// Trust is how this gateway decides which devices reach its node.
	Trust() *devicecore.Trust
	// Servers are the surfaces this gateway answers on, addressed but not yet
	// listening: naming them separately is what lets the deployment bind the
	// addresses it recorded and lets a test serve the same surfaces on ports of
	// its own.
	Servers() ([]*http.Server, error)
}

// Serve binds every surface a gateway says it serves and blocks until one of
// them stops. A surface that terminates TLS carries the certificate to serve in
// its own TLS configuration, so which shape is being served does not show here.
func Serve(gateway Gateway, log func(component, level, message string, keyValues ...string)) error {
	servers, err := gateway.Servers()
	if err != nil {
		return err
	}
	if len(servers) == 0 {
		return errors.New("a gateway serves nothing")
	}
	stopped := make(chan error, len(servers))
	for _, server := range servers {
		go func(server *http.Server) {
			log("gateway", "info", "listening", "path", server.Addr)
			if server.TLSConfig != nil {
				stopped <- server.ListenAndServeTLS("", "")
				return
			}
			stopped <- server.ListenAndServe()
		}(server)
	}
	return <-stopped
}
