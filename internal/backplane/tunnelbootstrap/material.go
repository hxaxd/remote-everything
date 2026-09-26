// Package tunnelbootstrap is the material the tunnel in front of a public gateway
// runs on: the token the tunnel server authenticates clients with, the authority it
// issues client identities from, and the identity each node's tunnel agent presents.
//
// It belongs to the public shape, which is the only shape that has a tunnel: a node
// never reads any of it, the gateway keeps the server half on its own machine, and
// only each node's own material travels in the handover bundle that machine is
// given.
package tunnelbootstrap

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/infra/atomicfile"
	"github.com/hxaxd/remote-everything/internal/infra/secret"
)

const (
	FRPSTokenName        = "frps-token"
	TunnelCACertName     = "tunnel-ca.crt.pem"
	TunnelCAKeyName      = "tunnel-ca.key.pem"
	TunnelClientCertName = "tunnel-client.crt.pem"
	TunnelClientKeyName  = "tunnel-client.key.pem"
	// TunnelMaterialDir is the directory inside the handover bundle that holds
	// what the tunnel agent on the node machine reads.
	TunnelMaterialDir = "frpc"
)

// NodeTunnelHost and NodeTunnelPort are where a gateway reaches a node over its
// own tunnel: the node's tunnel agent publishes the node's control port on the
// tunnel server's loopback, and this is the address the gateway dials and the
// port the agent is told to publish. What a gateway records is the address, and
// the port in it is what the node's own tunnel configuration has to publish.
const (
	NodeTunnelHost = "127.0.0.1"
	NodeTunnelPort = 58628
)

// FRPSPort is the port a tunnel server prefers to serve on. Both shapes
// reserve a listener for it — a LAN entrance on every interface of its own
// machine, a public gateway on its loopback — and a port repair moves it back
// here first.
const FRPSPort = 58630

var hex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

// GatewayMaterial is the tunnel material a gateway owns on its own machine: the
// token the tunnel server authenticates clients with and the tunnel CA it issues
// client identities from. None of it is delivered to a node; the tunnel CA private
// key never leaves the gateway.
type GatewayMaterial struct {
	InstallationID string
	FRPSToken      string
	FRPSTokenFile  string
	CACertificate  *x509.Certificate
	CAKey          *ecdsa.PrivateKey
	CACertFile     string
	CAKeyFile      string
}

// TunnelMaterial is the pile the tunnel agent on the node machine runs on: the
// token it authenticates to the tunnel server with and the client identity it
// presents. The gateway issues it and hands it over in the bundle; the node
// itself never reads it.
type TunnelMaterial struct {
	Directory       string
	TokenFile       string
	CertificateFile string
	KeyFile         string
	Fingerprint     string
}

func parseCertificate(contents []byte) (*x509.Certificate, error) {
	block, rest := pem.Decode(contents)
	if block == nil || block.Type != "CERTIFICATE" || len(rest) != 0 {
		return nil, errors.New("invalid PEM certificate")
	}
	return x509.ParseCertificate(block.Bytes)
}

func parsePrivateKey(contents []byte) (*ecdsa.PrivateKey, error) {
	block, rest := pem.Decode(contents)
	if block == nil || block.Type != "PRIVATE KEY" || len(rest) != 0 {
		return nil, errors.New("invalid PEM private key")
	}
	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ecdsaKey, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("private key is not ECDSA")
	}
	return ecdsaKey, nil
}

func publicKeysMatch(certificate *x509.Certificate, key *ecdsa.PrivateKey) bool {
	public, ok := certificate.PublicKey.(*ecdsa.PublicKey)
	if !ok {
		return false
	}
	certificateKey, certificateErr := public.Bytes()
	privateKey, privateErr := key.PublicKey.Bytes()
	return certificateErr == nil && privateErr == nil && bytes.Equal(certificateKey, privateKey)
}

func validateTunnelCA(certificate *x509.Certificate, installationID string) error {
	now := time.Now()
	expectedName := "Remote Everything Tunnel " + installationID
	if !certificate.IsCA || !certificate.BasicConstraintsValid || certificate.Subject.CommonName != expectedName ||
		!bytes.Equal(certificate.RawSubject, certificate.RawIssuer) ||
		now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) ||
		certificate.KeyUsage&x509.KeyUsageCertSign == 0 || !certificate.MaxPathLenZero {
		return errors.New("invalid tunnel CA")
	}
	if err := certificate.CheckSignatureFrom(certificate); err != nil {
		return errors.New("invalid tunnel CA self-signature")
	}
	return nil
}

func writePrivateKey(path string, key *ecdsa.PrivateKey) error {
	contents, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	return atomicfile.Write(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: contents}), 0o600)
}

func ensureToken(path string) (string, error) {
	contents, err := os.ReadFile(path)
	if err == nil {
		value := strings.TrimRight(string(contents), "\r\n")
		if !hex64.MatchString(value) {
			return "", errors.New("invalid existing FRPS token")
		}
		return value, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	value, err := secret.Hex(32)
	if err != nil {
		return "", err
	}
	return value, atomicfile.Write(path, []byte(value+"\n"), 0o600)
}

// EnsureGatewayMaterial brings up what the tunnel server and the 443 entrance in
// front of this gateway read, creating the tunnel CA and the token when they are
// not there yet and validating them when they are.
func EnsureGatewayMaterial(root, installationID string) (GatewayMaterial, error) {
	if !filepath.IsAbs(root) || !hex64.MatchString(installationID) {
		return GatewayMaterial{}, errors.New("invalid gateway bootstrap input")
	}
	root = filepath.Clean(root)
	if err := os.MkdirAll(root, 0o700); err != nil {
		return GatewayMaterial{}, err
	}
	material := GatewayMaterial{
		InstallationID: installationID,
		FRPSTokenFile:  filepath.Join(root, FRPSTokenName),
		CACertFile:     filepath.Join(root, TunnelCACertName),
		CAKeyFile:      filepath.Join(root, TunnelCAKeyName),
	}
	var err error
	material.FRPSToken, err = ensureToken(material.FRPSTokenFile)
	if err != nil {
		return GatewayMaterial{}, err
	}
	certPEM, certErr := os.ReadFile(material.CACertFile)
	keyPEM, keyErr := os.ReadFile(material.CAKeyFile)
	if certErr == nil || keyErr == nil {
		if certErr != nil || keyErr != nil {
			return GatewayMaterial{}, errors.New("incomplete tunnel CA material")
		}
		material.CACertificate, err = parseCertificate(certPEM)
		if err != nil {
			return GatewayMaterial{}, err
		}
		material.CAKey, err = parsePrivateKey(keyPEM)
		if err != nil {
			return GatewayMaterial{}, err
		}
		if validateTunnelCA(material.CACertificate, installationID) != nil || !publicKeysMatch(material.CACertificate, material.CAKey) {
			return GatewayMaterial{}, errors.New("tunnel CA does not match installation")
		}
		return material, nil
	}
	if !errors.Is(certErr, os.ErrNotExist) || !errors.Is(keyErr, os.ErrNotExist) {
		return GatewayMaterial{}, errors.New("cannot read tunnel CA material")
	}
	material.CAKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return GatewayMaterial{}, err
	}
	serial, err := secret.Serial()
	if err != nil {
		return GatewayMaterial{}, err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "Remote Everything Tunnel " + installationID},
		NotBefore:    now.Add(-5 * time.Minute), NotAfter: now.AddDate(10, 0, 0),
		IsCA: true, BasicConstraintsValid: true, MaxPathLen: 0, MaxPathLenZero: true,
		KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &material.CAKey.PublicKey, material.CAKey)
	if err != nil {
		return GatewayMaterial{}, err
	}
	material.CACertificate, err = x509.ParseCertificate(der)
	if err != nil {
		return GatewayMaterial{}, err
	}
	if err := writePrivateKey(material.CAKeyFile, material.CAKey); err != nil {
		return GatewayMaterial{}, err
	}
	if err := atomicfile.Write(material.CACertFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return GatewayMaterial{}, err
	}
	return material, nil
}

// tunnelMaterialDirectory returns the directory inside the handover bundle that
// the tunnel agent's material travels in, creating it.
func tunnelMaterialDirectory(bootstrapDir string, material GatewayMaterial) (string, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return "", errors.New("bootstrap path must be absolute")
	}
	if !hex64.MatchString(material.InstallationID) || !hex64.MatchString(material.FRPSToken) {
		return "", errors.New("invalid tunnel material identity")
	}
	if material.CACertificate == nil || material.CAKey == nil {
		return "", errors.New("tunnel CA is required to issue a client identity")
	}
	directory := filepath.Join(filepath.Clean(bootstrapDir), TunnelMaterialDir)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", err
	}
	return directory, nil
}

func tunnelMaterialPaths(directory string) TunnelMaterial {
	return TunnelMaterial{
		Directory:       directory,
		TokenFile:       filepath.Join(directory, FRPSTokenName),
		CertificateFile: filepath.Join(directory, TunnelClientCertName),
		KeyFile:         filepath.Join(directory, TunnelClientKeyName),
	}
}

// validTunnelClient reports whether a certificate is a current client identity
// issued by this tunnel CA.
func validTunnelClient(certificate *x509.Certificate, material GatewayMaterial, now time.Time) bool {
	if certificate.IsCA || certificate.Subject.CommonName != "remote-everything-tunnel-"+material.InstallationID ||
		certificate.KeyUsage&x509.KeyUsageDigitalSignature == 0 ||
		now.Before(certificate.NotBefore) || now.After(certificate.NotAfter) {
		return false
	}
	roots := x509.NewCertPool()
	roots.AddCert(material.CACertificate)
	_, err := certificate.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}})
	return err == nil
}

// EnsureTunnelMaterial writes the tunnel agent's material into the handover
// bundle, issuing a client identity only when there is none yet. It never
// rotates an identity that already exists: a tunnel agent already running has to
// keep authenticating with the files it was started with.
func EnsureTunnelMaterial(bootstrapDir string, material GatewayMaterial) (TunnelMaterial, error) {
	directory, err := tunnelMaterialDirectory(bootstrapDir, material)
	if err != nil {
		return TunnelMaterial{}, err
	}
	delivered := tunnelMaterialPaths(directory)
	if err := atomicfile.Write(delivered.TokenFile, []byte(material.FRPSToken+"\n"), 0o600); err != nil {
		return TunnelMaterial{}, err
	}
	certPEM, certErr := os.ReadFile(delivered.CertificateFile)
	keyPEM, keyErr := os.ReadFile(delivered.KeyFile)
	if certErr == nil || keyErr == nil {
		if certErr != nil || keyErr != nil {
			return TunnelMaterial{}, errors.New("incomplete tunnel client identity")
		}
		certificate, err := parseCertificate(certPEM)
		if err != nil {
			return TunnelMaterial{}, err
		}
		key, err := parsePrivateKey(keyPEM)
		if err != nil {
			return TunnelMaterial{}, err
		}
		if !publicKeysMatch(certificate, key) || !validTunnelClient(certificate, material, time.Now()) {
			return TunnelMaterial{}, errors.New("tunnel client identity does not match the tunnel CA")
		}
		delivered.Fingerprint = fingerprint(certificate.Raw)
		return delivered, nil
	}
	if !errors.Is(certErr, os.ErrNotExist) || !errors.Is(keyErr, os.ErrNotExist) {
		return TunnelMaterial{}, errors.New("cannot read tunnel client identity")
	}
	return RenewTunnelMaterial(bootstrapDir, material)
}

// RenewTunnelMaterial issues a fresh client identity from the same tunnel CA,
// replacing both files in the handover bundle. The CA is unchanged, so the
// identity being replaced stays valid until the agent on the node machine is
// pointed at the newly delivered files and restarted.
func RenewTunnelMaterial(bootstrapDir string, material GatewayMaterial) (TunnelMaterial, error) {
	directory, err := tunnelMaterialDirectory(bootstrapDir, material)
	if err != nil {
		return TunnelMaterial{}, err
	}
	delivered := tunnelMaterialPaths(directory)
	if err := atomicfile.Write(delivered.TokenFile, []byte(material.FRPSToken+"\n"), 0o600); err != nil {
		return TunnelMaterial{}, err
	}
	clientKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return TunnelMaterial{}, err
	}
	serial, err := secret.Serial()
	if err != nil {
		return TunnelMaterial{}, err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "remote-everything-tunnel-" + material.InstallationID},
		NotBefore:    now.Add(-5 * time.Minute), NotAfter: now.AddDate(1, 0, 0),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, material.CACertificate, &clientKey.PublicKey, material.CAKey)
	if err != nil {
		return TunnelMaterial{}, err
	}
	delivered.Fingerprint = fingerprint(der)
	if err := atomicfile.Write(delivered.CertificateFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return TunnelMaterial{}, err
	}
	if err := writePrivateKey(delivered.KeyFile, clientKey); err != nil {
		return TunnelMaterial{}, err
	}
	return delivered, nil
}

func fingerprint(certificateDER []byte) string {
	value := sha256.Sum256(certificateDER)
	return hex.EncodeToString(value[:])
}
