package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"path/filepath"
	"strconv"
	"sync"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/logline"
	"github.com/hxaxd/remote-everything/internal/netaddr"
	"github.com/hxaxd/remote-everything/internal/wire"
)

// applicationHost is where this entrance's applications listen when nobody said:
// the wildcard address, so an application is reachable wherever this machine is.
// An operator who wants it somewhere else — an application is also worth opening
// from the machine itself — says so at init, and the state carries it.
const applicationHost = "0.0.0.0"

// lanService is the LAN entrance: the state that describes where it is and whom
// it serves, the device trust that decides which devices may reach the nodes, and
// the gateway the trust reaches them through.
//
// This shape serves no web client, and that is a decision rather than a gap: its
// applications are served on ports of the entrance's own host, and a browser
// keeps cookies by host and not by port, so an application's page would share one
// cookie jar with the entrance's own session — able to write cookies the entrance
// receives and to read every one the entrance did not mark HttpOnly. A browser is
// not a client of this shape; a device holding a certificate is. The public shape
// serves one, at a host of its own with a cookie name the browser binds to that
// host, and the trade is written down in `skills/remote-everything-app`.
type lanService struct {
	root  string
	state lanState
	trust *devicecore.Trust

	// applications is what this entrance serves at origins of its own, one
	// application of one node per port. The ports live in the state too, because
	// they have to outlive this process; this is what the running entrance holds, so
	// that an application that was opened once is served at the same origin until
	// the entrance stops.
	applications   map[string]lanApplication
	applicationsMu sync.Mutex
}

// openLANTrust opens the device trust of this entrance over the gateway it is
// given — the same gateway that serves, because which node a device may reach
// and which node a request reaches are one decision. It is what serving and
// the commands that edit what devices hold both go through.
//
// Nothing at this entrance's edges outlives a revoked device: what a gateway
// keeps for one is its web sessions, and this shape keeps none.
func openLANTrust(root string, state lanState, gateway *gatewaycore.Gateway) (*devicecore.Trust, error) {
	certificate, err := loadLANCertificate(root, state)
	if err != nil {
		return nil, err
	}
	return devicecore.Open(devicecore.Config{
		Root: root, InstallationID: state.InstallationID, Origin: state.Origin,
		// If RequireApproval is false, this entrance hands its invitations over in person,
		// so redeeming one is the whole of the admission. If RequireApproval is true,
		// an operator must manually approve the device after redemption.
		Certificate: certificate, ApproveOnRedemption: !state.RequireApproval, Node: gateway,
		Log: logline.Log, Audit: logline.Audit,
	})
}

func openLANService(root string) (*lanService, error) {
	state, err := loadLANState(root)
	if err != nil {
		return nil, err
	}
	gateway, err := gatewaycore.New(state.State, root)
	if err != nil {
		return nil, err
	}
	trust, err := openLANTrust(root, state, gateway)
	if err != nil {
		return nil, err
	}
	service := &lanService{root: root, state: state, applications: map[string]lanApplication{}}
	for _, application := range state.Applications {
		service.applications[application.key()] = application
	}
	// This entrance serves its applications on ports of its own rather than as
	// hosts under its origin, which is an address rather than a domain.
	gateway.SetAppAddressing(service)
	service.trust = trust

	return service, nil
}

// State is what this entrance recorded about itself.
func (service *lanService) State() gatewaycore.State {
	return service.state.State
}

// Trust is how this entrance admits devices.
func (service *lanService) Trust() *devicecore.Trust {
	return service.trust
}

// Surfaces is what this entrance answers on: one address that terminates TLS with
// the certificate its clients pinned, and one address for every application this
// entrance already serves. The devices behind it are what answers on all of them —
// this entrance is what its clients reach, so it is the one that terminates, and
// it terminates the same way for an application as for anything else.
//
// It is asked for once, when the entrance starts, and each application's listener
// is taken here rather than shared: an address can only be taken once, and taking
// it is what lets an entrance that cannot have one go on serving the rest.
func (service *lanService) Surfaces() ([]entrance.Surface, error) {
	listenAddress, err := service.state.listener()
	if err != nil {
		return nil, errors.New("LAN state is missing its listener")
	}
	configuration, err := service.tls()
	if err != nil {
		return nil, err
	}
	// Whatever is asked for here, the answer is the trust's: this address serves a
	// device holding a certificate, and a browser is not one.
	server := gatewaycore.NewServer(listenAddress, devicecore.WithClientFingerprint(service.trust))
	server.TLSConfig = configuration
	surfaces := []entrance.Surface{{
		Address: listenAddress,
		Bind:    func(listener net.Listener) error { return server.ServeTLS(listener, "", "") },
	}}
	return append(surfaces, service.applicationSurfaces(configuration)...), nil
}

// applicationSurfaces is the addresses of the applications this entrance already
// serves, rebuilt from the state at every start: an origin that was handed out is
// one a browser has storage under, so the application has to come back at the same
// address. Each listener is taken here rather than handed to a start that binds
// everything it was given, because the failures are not the same size: an address
// this entrance can no longer hold — something else took the port while it was
// down — is dropped from the state, and that application is given a new origin the
// next time somebody opens it, while the entrance goes on serving everything else.
func (service *lanService) applicationSurfaces(configuration *tls.Config) []entrance.Surface {
	service.applicationsMu.Lock()
	defer service.applicationsMu.Unlock()
	host, err := service.state.applicationsHost()
	if err != nil {
		logline.Log("gateway", "error", "the address this entrance serves applications on is unreadable", "code", err.Error())
		return nil
	}
	surfaces := make([]entrance.Surface, 0, len(service.state.Applications))
	kept := make([]lanApplication, 0, len(service.state.Applications))
	for _, application := range service.state.Applications {
		address := application.address(host)
		listener, err := net.Listen("tcp4", address)
		if err != nil {
			logline.Log("gateway", "warn", "an application's address is taken; it will be served at a new origin when it is opened again",
				"node_id", application.NodeID, "app_id", application.AppID, "address", address)
			delete(service.applications, application.key())
			continue
		}
		kept = append(kept, application)
		surfaces = append(surfaces, service.applicationSurface(application, address, configuration, listener))
	}
	if len(kept) != len(service.state.Applications) {
		service.state.Applications = kept
		if err := service.state.save(service.root); err != nil {
			logline.Log("gateway", "error", "the dropped application origins could not be written down", "code", err.Error())
		}
	}
	return surfaces
}

// applicationSurface is one application's own address: where this entrance serves
// it and how it is answered there, which is the device trust in front of the
// gateway, for the one application this address belongs to. The trust is told
// which device is asking the same way it is on the entrance's own address — this
// entrance terminates the TLS here too, so the certificate it verified is what
// speaks for the device.
func (service *lanService) applicationSurface(application lanApplication, address string, configuration *tls.Config, listener net.Listener) entrance.Surface {
	appHandler := devicecore.WithClientFingerprint(service.trust.AppHandler(application.NodeID, application.AppID))
	server := gatewaycore.NewServer(address, appHandler)
	server.TLSConfig = configuration
	return entrance.Surface{
		Address:  address,
		Listener: listener,
		Bind:     func(listener net.Listener) error { return server.ServeTLS(listener, "", "") },
	}
}

// Origin is where one application of one node is served, as
// gatewaycore.AppAddressing asks it: a port of this entrance's own, allocated for
// that application and kept for as long as this entrance serves it. An application
// that was never opened is given one here, and it is being served before this
// answers: an origin is handed to a client so that the client loads it, and one
// that answers nothing would be a page that never loads.
func (service *lanService) Origin(nodeID, appID string) (string, error) {
	if !validSHA256.MatchString(nodeID) || !wire.ValidAppID(appID) {
		return "", errors.New("invalid application")
	}
	if _, ok := service.state.FindNode(nodeID); !ok {
		return "", errors.New("this entrance serves no such node")
	}
	host, err := service.state.host()
	if err != nil {
		return "", err
	}
	service.applicationsMu.Lock()
	defer service.applicationsMu.Unlock()
	application, ok := service.applications[applicationKey(nodeID, appID)]
	if !ok {
		if application, err = service.startApplication(nodeID, appID); err != nil {
			return "", err
		}
	}
	return application.origin(host), nil
}

// startApplication gives one application of one node an origin of this entrance's
// own: a port the operating system picks, a listener on it, and then the record of
// it. The order matters, and it is this one because the two failures are not the
// same size: a port that is allocated and not recorded is one nobody was told
// about, while a record written before anything answers on it is an application a
// client is sent to and finds nothing at.
func (service *lanService) startApplication(nodeID, appID string) (lanApplication, error) {
	host, err := service.state.applicationsHost()
	if err != nil {
		return lanApplication{}, err
	}
	address, err := netaddr.Reserve(host)
	if err != nil {
		return lanApplication{}, err
	}
	_, portText, err := net.SplitHostPort(address)
	if err != nil {
		return lanApplication{}, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil || !validPort(port) {
		return lanApplication{}, errors.New("no port available for an application")
	}
	application := lanApplication{NodeID: nodeID, AppID: appID, Port: port}
	configuration, err := service.tls()
	if err != nil {
		return lanApplication{}, err
	}
	listenAddress := application.address(host)
	listener, err := net.Listen("tcp4", listenAddress)
	if err != nil {
		return lanApplication{}, err
	}
	surface := service.applicationSurface(application, listenAddress, configuration, listener)
	previous := service.state.Applications
	service.state.Applications = append(append([]lanApplication{}, previous...), application)
	if err := service.state.save(service.root); err != nil {
		service.state.Applications = previous
		_ = listener.Close()
		return lanApplication{}, err
	}
	service.applications[application.key()] = application
	go func() {
		if err := surface.Bind(listener); err != nil {
			logline.Log("gateway", "error", "an application stopped answering", "node_id", nodeID, "app_id", appID, "code", err.Error())
		}
	}()
	return application, nil
}

// tls is what every surface of this entrance serves with: the certificate its
// clients pinned when they paired, and the device authority it verifies them
// against. One certificate covers every port of it, because what a client pinned
// is a certificate rather than an origin.
func (service *lanService) tls() (*tls.Config, error) {
	certificatePair, err := tls.LoadX509KeyPair(
		filepath.Join(service.root, service.state.LAN.CertificateFile),
		filepath.Join(service.root, service.state.LAN.PrivateKeyFile),
	)
	if err != nil {
		return nil, errors.New("LAN TLS material unavailable")
	}
	deviceIssuers := x509.NewCertPool()
	deviceIssuers.AddCert(service.trust.Issuer())
	return &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{certificatePair},
		ClientAuth:   tls.VerifyClientCertIfGiven,
		ClientCAs:    deviceIssuers,
	}, nil
}

// applicationKey is how this entrance names one application of one node to itself:
// a node id is not something a person reads out, and this pair is what an origin
// is made of.
func applicationKey(nodeID, appID string) string {
	return nodeID + "/" + appID
}

func (application lanApplication) key() string {
	return applicationKey(application.NodeID, application.AppID)
}

// address is where this application listens: the address this entrance serves its
// applications on, and the port it gave this one.
func (application lanApplication) address(host string) string {
	return net.JoinHostPort(host, strconv.Itoa(application.Port))
}

// origin is where this application is served as its clients address it: the host
// this entrance is reached at, and the port this application holds.
func (application lanApplication) origin(host string) string {
	return "https://" + net.JoinHostPort(host, strconv.Itoa(application.Port))
}

// withoutApplicationsOf drops the applications of one node, which is what taking
// that node out of this entrance takes with it.
func withoutApplicationsOf(applications []lanApplication, nodeID string) []lanApplication {
	kept := make([]lanApplication, 0, len(applications))
	for _, application := range applications {
		if application.NodeID != nodeID {
			kept = append(kept, application)
		}
	}
	return kept
}
