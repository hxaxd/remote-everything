package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"path/filepath"
	"strings"

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
	certificate, err := loadLANCertificate(root, state.LAN.Host, state)
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
		Root: root, InstallationID: state.InstallationID, Mode: "lan",
		Origin: state.LAN.GatewayOrigin, Certificate: certificate, Node: gateway,
		Log: logline.Log, Audit: logline.Audit,
	})
	if err != nil {
		return nil, err
	}
	return &lanService{root: root, state: state, trust: trust, gateway: gateway}, nil
}

// gatewayHandler serves the one address this entrance listens on. The surfaces
// the device trust answers are its own; everything else is application traffic,
// which the node authorizes by the routing cookie it sets when an application is
// opened — a page load cannot carry a credential the way a control call does.
func (service *lanService) gatewayHandler() http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if strings.HasPrefix(request.URL.Path, "/__remote_everything") {
			service.trust.ServeHTTP(writer, request)
			return
		}
		service.gateway.ServeHTTP(writer, request)
	})
}

// gatewayServer is what this entrance serves on one address. It terminates TLS
// with the certificate its clients pinned, and asks for the device certificate
// they were issued: the fingerprint of a verified one is what the device trust
// admits a request by. A client that has no certificate yet is the one redeeming
// an invitation, which is exactly the request pairing answers.
func (service *lanService) gatewayServer(address string) (*http.Server, error) {
	certificatePair, err := tls.LoadX509KeyPair(
		filepath.Join(service.root, service.state.LAN.CertificateFile),
		filepath.Join(service.root, service.state.LAN.PrivateKeyFile),
	)
	if err != nil {
		return nil, errors.New("LAN TLS material unavailable")
	}
	deviceIssuers := x509.NewCertPool()
	deviceIssuers.AddCert(service.trust.Issuer())
	server := gatewaycore.NewServer(address, devicecore.WithClientFingerprint(service.gatewayHandler()))
	server.TLSConfig = &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{certificatePair},
		ClientAuth:   tls.VerifyClientCertIfGiven,
		ClientCAs:    deviceIssuers,
	}
	return server, nil
}

func (service *lanService) serveGateway() error {
	listenAddress, err := service.state.listener()
	if err != nil {
		return errors.New("LAN state is missing its listener")
	}
	server, err := service.gatewayServer(listenAddress)
	if err != nil {
		return err
	}
	logline.Log("lan-server", "info", "listening", "path", listenAddress)
	return server.ListenAndServeTLS("", "")
}
