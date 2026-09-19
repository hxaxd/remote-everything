// Package devicecore is the device trust of a gateway: the CA it issues device
// certificates from, the records of the devices it has approved, the invitations
// it hands out, and the endpoints and admission check those live behind.
//
// It is one implementation for every entrance. A gateway that fronts its own
// clients and one behind an authenticating entrance differ in where the client
// certificate is verified and in what the setup URI carries, not in what trust
// means.
package devicecore

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/secret"
)

// validHex64 is the shape of every 64-hex value on the wire: a node id, an
// installation id, a certificate fingerprint, a token hash or a secret.
var validHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

// clientFingerprintHeader is this package's name for the header an entrance
// stamps a verified certificate's fingerprint into. The header's name itself is
// kept with the other internal header names, where the list of what an
// application never sees is.
const clientFingerprintHeader = proxysecurity.ClientFingerprintHeader

// errorResponse is the body both device endpoints answer a refusal with.
type errorResponse struct {
	OK   bool   `json:"ok"`
	Code string `json:"code"`
}

func errorBody(code string) errorResponse {
	return errorResponse{OK: false, Code: code}
}

const (
	issuerKeyName  = "device-issuer.key.pem"
	issuerCertName = "device-issuer.crt.pem"
	devicesDirName = "devices"
	invitesDirName = "invites"
)

// Node is what device trust protects: the nodes a gateway serves, which are what
// its devices are granted access to. Activation waits until the node it is for
// answers, every admitted request is served by the node that request names, and
// which node that is is decided here: a gateway is asked for one of them rather
// than told one, so what a request names is read once and refused once.
type Node interface {
	// ServeNode answers one request for one node this gateway serves.
	ServeNode(nodeID string, writer http.ResponseWriter, request *http.Request)
	// ServeApplication answers one request on the origin one application of one
	// node is served at, with the application this gateway writes into the request
	// rather than the one the request claims.
	ServeApplication(nodeID, appID string, writer http.ResponseWriter, request *http.Request)
	// ConnectedList is what the node with this id runs, as that node said it. A
	// gateway serves several, and each of them answers for itself.
	ConnectedList(nodeID string) (json.RawMessage, bool)
	// Nodes is every node this gateway serves.
	Nodes() []gatewaycore.Node
}

// Config is what a gateway tells its device trust about itself.
type Config struct {
	// Root is the gateway's state directory. The device CA, the device records
	// and the invitations live here.
	Root string
	// InstallationID is the identity the setup URI carries.
	InstallationID string
	// Origin is the origin this gateway recorded for itself, which is where its
	// clients dial it and what every invitation points at.
	Origin string
	// Certificate is the certificate this gateway serves its clients with, if it
	// serves one of its own: an invitation then carries it, because nothing else
	// signs that gateway and its clients have nowhere else to learn which
	// certificate to expect. A gateway an authority signs has none to declare.
	Certificate *x509.Certificate
	// ApproveOnRedemption is the admission this gateway grants: an invitation is
	// the whole of it when the operator who handed the invitation over is the
	// approval, which is what an entrance serving its own network does. A gateway
	// whose invitations travel over a network nobody watches waits instead for its
	// operator to confirm the device that redeemed one.
	ApproveOnRedemption bool
	// Node is the gateway, seen as the nodes it serves: which of them a device may
	// reach is what this trust decides, and an invitation is for one of them.
	Node Node
	// Revoked is told when a device stops being admitted for good — revoked by
	// its operator, or replaced by the renewal that took its place. The trust
	// refuses the device from that moment on its own; this is where a gateway
	// ends what it keeps for the device at its edges, so nothing held for a
	// revoked device outlives the record that says it is gone. It may be nil.
	Revoked func(fingerprint string) error
	// Log writes one operational line; Audit writes the device audit trail.
	// Callers must never pass tokens, passwords, private keys or PKCS#12
	// material as values.
	Log   func(component, level, message string, keyValues ...string)
	Audit func(message string, keyValues ...string)
}

// Trust is the device trust of one gateway.
type Trust struct {
	root                string
	installationID      string
	origin              string
	certificate         *x509.Certificate
	issuer              *x509.Certificate
	approveOnRedemption bool
	devicesDir          string
	invitesDir          string
	issuerKeyFile       string
	issuerCertFile      string
	node                Node
	revoked             func(fingerprint string) error
	log                 func(component, level, message string, keyValues ...string)
	audit               func(message string, keyValues ...string)
	pairLock            sync.Mutex
	pairFailureDelay    time.Duration
	pairLimiter         *rateLimiter
	statusLimiter       *rateLimiter
}

// Open brings up the device trust of a gateway, creating its CA and its record
// directories when they are not there yet, and clearing state that no live
// invitation references any more.
func Open(config Config) (*Trust, error) {
	if config.Root == "" || !filepath.IsAbs(config.Root) || config.InstallationID == "" || config.Origin == "" || config.Node == nil {
		return nil, errors.New("invalid device trust configuration")
	}
	root := filepath.Clean(config.Root)
	trust := &Trust{
		root:                root,
		installationID:      config.InstallationID,
		origin:              config.Origin,
		certificate:         config.Certificate,
		approveOnRedemption: config.ApproveOnRedemption,
		devicesDir:          filepath.Join(root, devicesDirName),
		invitesDir:          filepath.Join(root, invitesDirName),
		issuerKeyFile:       filepath.Join(root, issuerKeyName),
		issuerCertFile:      filepath.Join(root, issuerCertName),
		node:                config.Node,
		revoked:             config.Revoked,
		log:                 config.Log,
		audit:               config.Audit,
		pairFailureDelay:    350 * time.Millisecond,
		pairLimiter:         newPairRateLimiter(),
		statusLimiter:       newStatusRateLimiter(),
	}
	if trust.log == nil {
		trust.log = func(string, string, string, ...string) {}
	}
	if trust.audit == nil {
		trust.audit = func(string, ...string) {}
	}
	if trust.revoked == nil {
		trust.revoked = func(string) error { return nil }
	}
	for _, directory := range []string{trust.devicesDir, trust.invitesDir} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, err
		}
	}
	issuer, err := EnsureIssuer(root)
	if err != nil {
		return nil, err
	}
	trust.issuer = issuer
	if err := trust.cleanupExpiredState(); err != nil {
		return nil, err
	}
	return trust, nil
}

// revokeDevice is where the edges of a revoked device are cut. The trust
// itself refuses the device from the moment its record says so, whatever an
// old session or a cached answer may claim; what a gateway keeps for the
// device beyond this trust is ended here, so nothing of it outlives the
// record that says it is gone.
func (service *Trust) revokeDevice(fingerprint string) {
	if err := service.revoked(fingerprint); err != nil {
		service.log("gateway", "warn", "state kept for a revoked device could not be cleared", "fingerprint", fingerprint, "code", err.Error())
	}
}

// PairHandler serves the pairing endpoint an invitation is redeemed at.
func (service *Trust) PairHandler() http.Handler {
	return http.HandlerFunc(service.pairHTTPHandler)
}

// ServeHTTP serves both surfaces on one listener, for an entrance that
// terminates TLS itself and forwards everything it terminates to one address.
// The pairing endpoint is answered first: a device redeeming an invitation has
// no credential yet, so it cannot be admitted by the surface that checks one.
func (service *Trust) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if rawRequestPath(request) == pairRequestPath {
		service.pairHTTPHandler(writer, request)
		return
	}
	service.statusHTTPHandler(writer, request)
}

// WithClientFingerprint wraps a handler so that the trust can tell which device
// a request came from: it stamps the fingerprint of the client certificate the
// entrance verified, and drops whatever the client itself sent before that. An
// entrance that terminates mTLS itself calls this; one behind a proxy is
// stamped by the proxy, which verifies the same certificate the same way.
func WithClientFingerprint(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		request.Header.Del(clientFingerprintHeader)
		if request.TLS != nil {
			for _, chain := range request.TLS.VerifiedChains {
				if len(chain) == 0 {
					continue
				}
				request.Header.Set(clientFingerprintHeader, CertificateFingerprint(chain[0]))
				break
			}
		}
		next.ServeHTTP(writer, request)
	})
}

// Issuer is the certificate every device credential chains to: an entrance that
// terminates mTLS itself verifies the certificates its clients present against
// it.
func (service *Trust) Issuer() *x509.Certificate {
	return service.issuer
}

// IssuerCertPath is where a gateway keeps the device CA certificate.
func IssuerCertPath(root string) string {
	return filepath.Join(filepath.Clean(root), issuerCertName)
}

// EnsureIssuer creates the device CA of a gateway when it has none, validates the
// one it has, and returns its certificate.
func EnsureIssuer(root string) (*x509.Certificate, error) {
	root = filepath.Clean(root)
	keyFile := filepath.Join(root, issuerKeyName)
	certFile := filepath.Join(root, issuerCertName)
	keyExists := false
	if _, err := os.Stat(keyFile); err == nil {
		keyExists = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	certExists := false
	if _, err := os.Stat(certFile); err == nil {
		certExists = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if keyExists || certExists {
		if !keyExists || !certExists {
			return nil, errors.New("incomplete device issuer material")
		}
		_, certificate, err := loadIssuer(root)
		return certificate, err
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	serial, err := secret.Serial()
	if err != nil {
		return nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Remote Everything Device Issuer"},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: now.Add(3650 * 24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, err
	}
	if err := atomicfile.Write(keyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return nil, err
	}
	if err := atomicfile.Write(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER}), 0o644); err != nil {
		return nil, err
	}
	_, certificate, err := loadIssuer(root)
	return certificate, err
}

func loadIssuer(root string) (*ecdsa.PrivateKey, *x509.Certificate, error) {
	keyPEM, err := os.ReadFile(filepath.Join(filepath.Clean(root), issuerKeyName))
	if err != nil {
		return nil, nil, err
	}
	keyBlock, rest := pem.Decode(keyPEM)
	if keyBlock == nil || len(rest) != 0 || keyBlock.Type != "PRIVATE KEY" {
		return nil, nil, errors.New("invalid issuer private key")
	}
	parsedKey, err := x509.ParsePKCS8PrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, nil, err
	}
	privateKey, ok := parsedKey.(*ecdsa.PrivateKey)
	if !ok || privateKey.Curve == nil {
		return nil, nil, errors.New("invalid issuer private key")
	}
	certPEM, err := os.ReadFile(filepath.Join(filepath.Clean(root), issuerCertName))
	if err != nil {
		return nil, nil, err
	}
	certBlock, rest := pem.Decode(certPEM)
	if certBlock == nil || len(rest) != 0 || certBlock.Type != "CERTIFICATE" {
		return nil, nil, errors.New("invalid issuer certificate")
	}
	certificate, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, nil, err
	}
	if err := validateIssuer(certificate, privateKey); err != nil {
		return nil, nil, err
	}
	return privateKey, certificate, nil
}

// validateIssuer checks that the CA certificate is the self-signed issuer this
// key belongs to, and rejects anything else: every device credential a gateway
// accepts is signed by it.
func validateIssuer(certificate *x509.Certificate, privateKey *ecdsa.PrivateKey) error {
	issuerPublicKey, ok := certificate.PublicKey.(*ecdsa.PublicKey)
	now := time.Now()
	if !ok || !certificate.IsCA || !certificate.BasicConstraintsValid || !certificate.MaxPathLenZero || certificate.KeyUsage&x509.KeyUsageCertSign == 0 || !issuerPublicKey.Equal(&privateKey.PublicKey) ||
		certificate.Subject.CommonName != "Remote Everything Device Issuer" || certificate.Subject.String() != certificate.Issuer.String() ||
		now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) || certificate.CheckSignatureFrom(certificate) != nil {
		return errors.New("issuer key and certificate do not match")
	}
	return nil
}

// RunCLI runs the device commands a gateway exposes: the device records and the
// invitations it has handed out.
func (service *Trust) RunCLI(parts []string, output io.Writer) error {
	return service.runDeviceCLI(parts, output)
}
