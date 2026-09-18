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
)

// applicationHost is where the applications of this entrance listen: the machine's
// own address, so a client reaches an application wherever it reaches the entrance
// itself. Which host its clients dial is not this one — it is the host the
// entrance recorded, which its certificate covers — and the port is what tells one
// application's origin from another's.
const applicationHost = "0.0.0.0"

// lanService is the LAN entrance: the state that describes where it is and whom
// it serves, the device trust that decides which devices may reach the nodes, and
// the gateway the trust reaches them through.
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

func openLANService(root string) (*lanService, error) {
	state, err := loadLANState(root)
	if err != nil {
		return nil, err
	}
	certificate, err := loadLANCertificate(root, state)
	if err != nil {
		return nil, err
	}
	gateway, err := gatewaycore.New(state.State, root)
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
	trust, err := devicecore.Open(devicecore.Config{
		Root: root, InstallationID: state.InstallationID, Origin: state.Origin,
		// This entrance hands its invitations over in person, so redeeming one is
		// the whole of the admission, and the certificate it serves is its own.
		Certificate: certificate, ApproveOnRedemption: true, Node: gateway,
		Log: logline.Log, Audit: logline.Audit,
	})
	if err != nil {
		return nil, err
	}
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
func (service *lanService) Surfaces() ([]entrance.Surface, error) {
	listenAddress, err := service.state.listener()
	if err != nil {
		return nil, errors.New("LAN state is missing its listener")
	}
	configuration, err := service.tls()
	if err != nil {
		return nil, err
	}
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
// address. An address this entrance can no longer hold — something else took the
// port while it was down — is dropped from the state instead, and that application
// is given a new origin the next time somebody opens it, which is the one thing
// left to do about it: an origin that cannot be served is worse than a new one.
func (service *lanService) applicationSurfaces(configuration *tls.Config) []entrance.Surface {
	service.applicationsMu.Lock()
	defer service.applicationsMu.Unlock()
	surfaces := make([]entrance.Surface, 0, len(service.state.Applications))
	kept := make([]lanApplication, 0, len(service.state.Applications))
	for _, application := range service.state.Applications {
		if !canBind(application.address()) {
			logline.Log("gateway", "warn", "an application's port is taken; it will be served at a new origin when it is opened again",
				"node_id", application.NodeID, "app_id", application.AppID, "port", strconv.Itoa(application.Port))
			delete(service.applications, application.key())
			continue
		}
		kept = append(kept, application)
		surfaces = append(surfaces, service.applicationSurface(application, configuration))
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
func (service *lanService) applicationSurface(application lanApplication, configuration *tls.Config) entrance.Surface {
	handler := devicecore.WithClientFingerprint(service.trust.AppHandler(application.NodeID, application.AppID))
	server := gatewaycore.NewServer(application.address(), handler)
	server.TLSConfig = configuration
	return entrance.Surface{
		Address: application.address(),
		Bind:    func(listener net.Listener) error { return server.ServeTLS(listener, "", "") },
	}
}

// Origin is where one application of one node is served, as
// gatewaycore.AppAddressing asks it: a port of this entrance's own, allocated for
// that application and kept for as long as this entrance serves it. An application
// that was never opened is given one here, and it is being served before this
// answers: an origin is handed to a client so that the client loads it, and one
// that answers nothing would be a page that never loads.
func (service *lanService) Origin(nodeID, appID string) (string, error) {
	if !validSHA256.MatchString(nodeID) || !gatewaycore.ValidAppID(appID) {
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
	address, err := netaddr.Reserve(applicationHost)
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
	surface := service.applicationSurface(application, configuration)
	listener, err := net.Listen("tcp", surface.Address)
	if err != nil {
		return lanApplication{}, err
	}
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

// address is where this application listens: the machine's own address and the
// port this entrance gave it.
func (application lanApplication) address() string {
	return net.JoinHostPort(applicationHost, strconv.Itoa(application.Port))
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

// canBind reports whether this entrance can still hold an address: the port is
// free for it to take, and nothing else answered for that application while this
// entrance was not running.
func canBind(address string) bool {
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		return false
	}
	return listener.Close() == nil
}
