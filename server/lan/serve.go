package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"path/filepath"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/logline"
)

// lanService is the LAN entrance: the state that describes where it is and whom
// it serves, the device trust that decides which devices may reach the node, and
// the gateway that reaches it.
type lanService struct {
	root    string
	state   lanState
	trust   *devicecore.Trust
	gateway *gatewaycore.Gateway
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
	controlToken, err := gatewaycore.ReadControlToken(root)
	if err != nil {
		return nil, err
	}
	gateway, err := gatewaycore.New("http://"+state.LAN.NodeAddress, controlToken)
	if err != nil {
		return nil, err
	}
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
	return &lanService{root: root, state: state, trust: trust, gateway: gateway}, nil
}

// State is what this entrance recorded about itself.
func (service *lanService) State() gatewaycore.State {
	return service.state.State
}

// Trust is how this entrance admits devices.
func (service *lanService) Trust() *devicecore.Trust {
	return service.trust
}

// Servers is what this entrance answers on: one address that terminates TLS with
// the certificate its clients pinned, and the device trust behind it. Everything
// a client sends arrives there — the request that redeems an invitation, which is
// the one no credential can precede, and every other request, which the node
// answers only for a device that was admitted. An entrance that stands behind
// another one serving its clients differs in who terminates TLS, not in what is
// answered: the surface receives the same requests and admits the same devices.
func (service *lanService) Servers() ([]*http.Server, error) {
	listenAddress, err := service.state.listener()
	if err != nil {
		return nil, errors.New("LAN state is missing its listener")
	}
	certificatePair, err := tls.LoadX509KeyPair(
		filepath.Join(service.root, service.state.LAN.CertificateFile),
		filepath.Join(service.root, service.state.LAN.PrivateKeyFile),
	)
	if err != nil {
		return nil, errors.New("LAN TLS material unavailable")
	}
	deviceIssuers := x509.NewCertPool()
	deviceIssuers.AddCert(service.trust.Issuer())
	server := gatewaycore.NewServer(listenAddress, devicecore.WithClientFingerprint(service.trust))
	server.TLSConfig = &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{certificatePair},
		ClientAuth:   tls.VerifyClientCertIfGiven,
		ClientCAs:    deviceIssuers,
	}
	return []*http.Server{server}, nil
}
