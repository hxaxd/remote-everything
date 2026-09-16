package main

import (
	"net"
	"net/http"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/entrance"
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

// Surfaces is what this gateway answers on, over the plain addresses the 443
// entrance in front of it forwards to: the surface whose clients the entrance has
// authenticated, and the one an invitation is redeemed at, which is the only
// request that can arrive without a credential. This gateway terminates nothing
// itself, which is the whole of how the two shapes differ.
func (service *publicService) Surfaces() ([]entrance.Surface, error) {
	return []entrance.Surface{
		plainSurface(service.listen("status"), service.trust.StatusHandler()),
		plainSurface(service.listen("pairing"), service.trust.PairHandler()),
	}, nil
}

// plainSurface is one address this gateway answers on, serving what the entrance
// in front of it forwards there.
func plainSurface(address string, handler http.Handler) entrance.Surface {
	server := gatewaycore.NewServer(address, handler)
	return entrance.Surface{
		Address: address,
		Bind:    func(listener net.Listener) error { return server.Serve(listener) },
	}
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
		Root: paths.root, InstallationID: state.InstallationID, Origin: state.Origin,
		// This gateway's invitations travel over a network nobody watches, so its
		// operator confirms the device that redeemed one, and an authority signs
		// the entrance in front of it rather than the gateway signing itself.
		Node: gateway, Log: logline.Log, Audit: logline.Audit,
	})
	if err != nil {
		return nil, err
	}
	return &publicService{paths: paths, config: state, trust: trust}, nil
}
