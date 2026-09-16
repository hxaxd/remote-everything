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
	"math/big"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
)

// validHex64 is the shape of every 64-hex value on the wire: an installation
// id, a certificate fingerprint, a token hash or a secret.
var validHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

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

// Node is the surface device trust protects: activation waits until the node
// behind it answers, and every admitted request is served by it.
type Node interface {
	http.Handler
	ConnectedList() (json.RawMessage, bool)
}

// Config is what a gateway tells its device trust about itself.
type Config struct {
	// Root is the gateway's state directory. The device CA, the device records
	// and the invitations live here.
	Root string
	// InstallationID is the identity the setup URI carries.
	InstallationID string
	// Node is what the admitted requests reach.
	Node Node
	// Log writes one operational line; Audit writes the device audit trail.
	// Callers must never pass tokens, passwords, private keys or PKCS#12
	// material as values.
	Log   func(component, level, message string, keyValues ...string)
	Audit func(message string, keyValues ...string)
}

// Trust is the device trust of one gateway.
type Trust struct {
	root             string
	installationID   string
	devicesDir       string
	invitesDir       string
	issuerKeyFile    string
	issuerCertFile   string
	node             Node
	log              func(component, level, message string, keyValues ...string)
	audit            func(message string, keyValues ...string)
	pairLock         sync.Mutex
	pairFailureDelay time.Duration
	pairLimiter      *rateLimiter
	statusLimiter    *rateLimiter
}

// Open brings up the device trust of a gateway, creating its CA and its record
// directories when they are not there yet, and clearing state that no live
// invitation references any more.
func Open(config Config) (*Trust, error) {
	if config.Root == "" || !filepath.IsAbs(config.Root) || config.InstallationID == "" || config.Node == nil {
		return nil, errors.New("invalid device trust configuration")
	}
	root := filepath.Clean(config.Root)
	trust := &Trust{
		root:             root,
		installationID:   config.InstallationID,
		devicesDir:       filepath.Join(root, devicesDirName),
		invitesDir:       filepath.Join(root, invitesDirName),
		issuerKeyFile:    filepath.Join(root, issuerKeyName),
		issuerCertFile:   filepath.Join(root, issuerCertName),
		node:             config.Node,
		log:              config.Log,
		audit:            config.Audit,
		pairFailureDelay: 350 * time.Millisecond,
		pairLimiter:      newPairRateLimiter(),
		statusLimiter:    newStatusRateLimiter(),
	}
	if trust.log == nil {
		trust.log = func(string, string, string, ...string) {}
	}
	if trust.audit == nil {
		trust.audit = func(string, ...string) {}
	}
	for _, directory := range []string{trust.devicesDir, trust.invitesDir} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return nil, err
		}
	}
	if _, err := EnsureIssuer(root); err != nil {
		return nil, err
	}
	if err := trust.cleanupExpiredState(); err != nil {
		return nil, err
	}
	return trust, nil
}

// StatusHandler serves the surface that fronts the node: activation, the
// admission check, and then the node itself.
func (service *Trust) StatusHandler() http.Handler {
	return http.HandlerFunc(service.statusHTTPHandler)
}

// PairHandler serves the pairing endpoint an invitation is redeemed at.
func (service *Trust) PairHandler() http.Handler {
	return http.HandlerFunc(service.pairHTTPHandler)
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
	serialBytes := make([]byte, 20)
	if _, err := rand.Read(serialBytes); err != nil {
		return nil, err
	}
	serial := new(big.Int).SetBytes(serialBytes)
	serial.Rsh(serial, 1)
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
