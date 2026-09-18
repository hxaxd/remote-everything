package main

import (
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/logline"
)

// publicService is the public entrance: its state, the device trust that guards
// what it serves, and the gateway the trust reaches every node it serves through.
type publicService struct {
	state gatewaycore.State
	trust *devicecore.Trust
}

// State is what this gateway recorded about itself.
func (service *publicService) State() gatewaycore.State {
	return service.state
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
		plainSurface(service.listen("status"), service.entranceHandler()),
		plainSurface(service.listen("pairing"), service.trust.PairHandler()),
	}, nil
}

// entranceHandler answers what the 443 entrance in front of this gateway forwards
// to it. Three things arrive on one address and the host is what tells them apart:
// the host this gateway recorded is the protocol's own origin, and everything a
// client asks it is asked there; a host under that one which names an application
// of a node is that application's own origin, and is answered by the node behind
// it; and the permission the entrance asks before issuing a certificate for one
// more such host is asked in the entrance's own name, on the address rather than on
// a host — it is a question about a host, so it cannot be asked on one. Everything
// else this gateway does not serve, and says so rather than answering as whichever
// of the three it resembles.
func (service *publicService) entranceHandler() http.Handler {
	domain := strings.ToLower(hostOf(service.state.Origin))
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		host := strings.ToLower(hostOf(request.Host))
		// The entrance asks its own question in its own name, on the address rather
		// than on a host — it is a question about a host — and everything else this
		// gateway answers is answered for the host it was asked for.
		if rawPath(request) == devicecore.TLSAskPath || host == domain {
			service.trust.ServeHTTP(writer, request)
			return
		}
		if prefix, appID, ok := gatewaycore.ParseAppHost(host, domain); ok {
			if node, found := gatewaycore.NodeByPrefix(service.state.Nodes, prefix); found {
				service.trust.AppHandler(node.ID, appID).ServeHTTP(writer, request)
				return
			}
		}
		gatewaycore.WriteJSON(writer, http.StatusNotFound, gatewaycore.Error("not_found"))
	})
}

// hostOf returns the host part of a host or of an origin, without a port: which
// host a request is for is decided by the name, and the port in it is the one the
// entrance in front of this gateway listens on.
func hostOf(value string) string {
	if parsed, err := url.Parse(value); err == nil && parsed.Hostname() != "" {
		return parsed.Hostname()
	}
	if host, _, err := net.SplitHostPort(value); err == nil {
		return host
	}
	return value
}

// rawPath is the path a request carries before it is decoded, which is the path
// the device trust matches its own endpoints against: this gateway decides which
// host a request is for, and the trust decides what it answers there.
func rawPath(request *http.Request) string {
	return request.URL.EscapedPath()
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
	address, err := service.state.Address(name)
	if err != nil {
		panic(err)
	}
	return address
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
	gateway, err := gatewaycore.New(state, paths.root)
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
	return &publicService{state: state, trust: trust}, nil
}
