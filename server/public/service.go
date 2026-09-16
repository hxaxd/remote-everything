package main

import (
	"net/http"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/logline"
)

// publicService is the public entrance: its state, the device trust that guards
// what it serves, and the gateway that reaches the node through the tunnel.
type publicService struct {
	paths  publicPaths
	config gatewaycore.State
	trust  *devicecore.Trust
}

// State is what this gateway recorded about itself.
func (service *publicService) State() gatewaycore.State {
	return service.config
}

// Trust is how this gateway admits devices.
func (service *publicService) Trust() *devicecore.Trust {
	return service.trust
}

// Servers is what this gateway answers on. It terminates nothing itself: the 443
// entrance authenticates its clients and forwards to these two addresses, which
// is why the set of surfaces it serves is what a client can observe about it.
func (service *publicService) Servers() ([]*http.Server, error) {
	status := gatewaycore.NewServer(service.listen("status"), service.trust.StatusHandler())
	pairing := gatewaycore.NewServer(service.listen("pairing"), service.trust.PairHandler())
	return []*http.Server{status, pairing}, nil
}

// listen returns the address of a named listener. The state is validated when
// it is loaded, so a missing listener can only mean the code asks for a name
// that is not part of this gateway.
func (service *publicService) listen(name string) string {
	address, err := service.config.Address(name)
	if err != nil {
		panic(err)
	}
	return address
}

// newNodeGateway returns the gateway that reaches the node over the tunnel the
// gateway's own frps listener terminates.
func (service *publicService) newNodeGateway() (*gatewaycore.Gateway, error) {
	token, err := gatewaycore.ReadControlToken(service.paths.root)
	if err != nil {
		return nil, err
	}
	return gatewaycore.New("http://"+service.listen("node_tunnel"), token)
}

func openPublicService(root string) (*publicService, error) {
	paths, err := newPublicPaths(root)
	if err != nil {
		return nil, err
	}
	state, err := paths.loadState()
	if err != nil {
		return nil, err
	}
	gateway, err := (&publicService{paths: paths, config: state}).newNodeGateway()
	if err != nil {
		return nil, err
	}
	trust, err := devicecore.Open(devicecore.Config{
		Root: paths.root, InstallationID: state.InstallationID, Mode: "public",
		Origin: state.Origin, Node: gateway,
		Log: logline.Log, Audit: logline.Audit,
	})
	if err != nil {
		return nil, err
	}
	return &publicService{paths: paths, config: state, trust: trust}, nil
}
