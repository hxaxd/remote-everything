package tunnelbootstrap

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/secret"
)

// ServerMaterial is read only by a directly exposed FRPS. Public gateways
// terminate tunnel TLS at their reverse proxy and do not need this identity.
type ServerMaterial struct {
	CertificateFile string
	KeyFile         string
	Fingerprint     string
}

func serverPaths(material GatewayMaterial) (ServerMaterial, error) {
	if !filepath.IsAbs(material.CACertFile) || material.CACertificate == nil || material.CAKey == nil ||
		!hex64.MatchString(material.InstallationID) || validateTunnelCA(material.CACertificate, material.InstallationID) != nil {
		return ServerMaterial{}, errors.New("invalid tunnel authority for a server identity")
	}
	root := filepath.Dir(material.CACertFile)
	return ServerMaterial{CertificateFile: filepath.Join(root, TunnelServerCertName), KeyFile: filepath.Join(root, TunnelServerKeyName)}, nil
}

// EnsureServerMaterial preserves a current FRPS identity and refuses incomplete,
// mismatched or expired material rather than silently replacing a live identity.
func EnsureServerMaterial(material GatewayMaterial) (ServerMaterial, error) {
	server, err := serverPaths(material)
	if err != nil {
		return ServerMaterial{}, err
	}
	certPEM, certErr := os.ReadFile(server.CertificateFile)
	keyPEM, keyErr := os.ReadFile(server.KeyFile)
	if errors.Is(certErr, os.ErrNotExist) && errors.Is(keyErr, os.ErrNotExist) {
		return RenewServerMaterial(material)
	}
	if certErr != nil || keyErr != nil {
		return ServerMaterial{}, errors.New("incomplete tunnel server identity")
	}
	certificate, err := parseCertificate(certPEM)
	if err != nil {
		return ServerMaterial{}, err
	}
	key, err := parsePrivateKey(keyPEM)
	if err != nil {
		return ServerMaterial{}, err
	}
	roots := x509.NewCertPool()
	roots.AddCert(material.CACertificate)
	_, err = certificate.Verify(x509.VerifyOptions{Roots: roots, DNSName: TunnelServerName, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
	if err != nil || certificate.IsCA || !publicKeysMatch(certificate, key) ||
		certificate.Subject.CommonName != "remote-everything-frps-"+material.InstallationID {
		return ServerMaterial{}, errors.New("tunnel server identity does not match the tunnel authority")
	}
	server.Fingerprint = fingerprint(certificate.Raw)
	return server, nil
}

// RenewServerMaterial rotates only the FRPS leaf identity. Agents keep trusting
// the same CA and do not need new client identities or node bindings.
func RenewServerMaterial(material GatewayMaterial) (ServerMaterial, error) {
	server, err := serverPaths(material)
	if err != nil {
		return ServerMaterial{}, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return ServerMaterial{}, err
	}
	serial, err := secret.Serial()
	if err != nil {
		return ServerMaterial{}, err
	}
	now := time.Now().UTC()
	expires := now.AddDate(1, 0, 0)
	if expires.After(material.CACertificate.NotAfter) {
		expires = material.CACertificate.NotAfter
	}
	certificate := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "remote-everything-frps-" + material.InstallationID},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: expires,
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: []string{TunnelServerName},
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, material.CACertificate, &key.PublicKey, material.CAKey)
	if err != nil {
		return ServerMaterial{}, err
	}
	if err := writePrivateKey(server.KeyFile, key); err != nil {
		return ServerMaterial{}, err
	}
	if err := atomicfile.Write(server.CertificateFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		return ServerMaterial{}, err
	}
	server.Fingerprint = fingerprint(der)
	return server, nil
}
