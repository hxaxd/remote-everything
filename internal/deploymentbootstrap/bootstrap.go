package deploymentbootstrap

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
)

const (
	Schema               = 1
	ManifestName         = "bootstrap.json"
	ControlTokenName     = "control-token"
	FRPSTokenName        = "frps-token"
	TunnelCACertName     = "tunnel-ca.crt.pem"
	TunnelCAKeyName      = "tunnel-ca.key.pem"
	TunnelClientCertName = "tunnel-client.crt.pem"
	TunnelClientKeyName  = "tunnel-client.key.pem"
)

var hex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

type Manifest struct {
	Schema              int    `json:"schema"`
	InstallationID      string `json:"installation_id"`
	ControlToken        string `json:"control_token_file"`
	FRPSToken           string `json:"frps_token_file"`
	TunnelCACertificate string `json:"tunnel_ca_certificate_file"`
	TunnelClientCert    string `json:"tunnel_client_certificate_file"`
	TunnelClientKey     string `json:"tunnel_client_key_file"`
}

type GatewayMaterial struct {
	InstallationID string
	ControlToken   string
	FRPSToken      string
	FRPSTokenFile  string
	CACertificate  *x509.Certificate
	CAKey          *ecdsa.PrivateKey
	CACertFile     string
	CAKeyFile      string
}

type NodeBundle struct {
	InstallationID string
	ControlToken   string
	FRPSToken      string
	CACertificate  []byte
	ClientCert     []byte
	ClientKey      []byte
}

func randomHex(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func serialNumber() (*big.Int, error) {
	value := make([]byte, 20)
	if _, err := rand.Read(value); err != nil {
		return nil, err
	}
	serial := new(big.Int).SetBytes(value)
	serial.Rsh(serial, 1)
	return serial, nil
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
	value, err := randomHex(32)
	if err != nil {
		return "", err
	}
	return value, atomicfile.Write(path, []byte(value+"\n"), 0o600)
}

func EnsureGatewayMaterial(root, installationID, controlToken string) (GatewayMaterial, error) {
	if !filepath.IsAbs(root) || !hex64.MatchString(installationID) || !hex64.MatchString(controlToken) {
		return GatewayMaterial{}, errors.New("invalid gateway bootstrap input")
	}
	root = filepath.Clean(root)
	if err := os.MkdirAll(root, 0o700); err != nil {
		return GatewayMaterial{}, err
	}
	material := GatewayMaterial{
		InstallationID: installationID,
		ControlToken:   controlToken,
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
	serial, err := serialNumber()
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

func WriteNodeBundle(root string, material GatewayMaterial) error {
	if !filepath.IsAbs(root) {
		return errors.New("bootstrap output path must be absolute")
	}
	root = filepath.Clean(root)
	if _, err := os.Stat(filepath.Join(root, ManifestName)); err == nil {
		existing, readErr := ReadNodeBundle(root)
		if readErr != nil {
			return readErr
		}
		if existing.InstallationID != material.InstallationID || existing.ControlToken != material.ControlToken || existing.FRPSToken != material.FRPSToken {
			return errors.New("existing node bootstrap does not match gateway")
		}
		existingCA, parseErr := parseCertificate(existing.CACertificate)
		if parseErr != nil || !bytes.Equal(existingCA.Raw, material.CACertificate.Raw) {
			return errors.New("existing node bootstrap uses a different tunnel CA")
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	clientKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := serialNumber()
	if err != nil {
		return err
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
		return err
	}
	files := map[string]struct {
		contents []byte
		mode     os.FileMode
	}{
		ControlTokenName:     {[]byte(material.ControlToken + "\n"), 0o600},
		FRPSTokenName:        {[]byte(material.FRPSToken + "\n"), 0o600},
		TunnelCACertName:     {pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: material.CACertificate.Raw}), 0o644},
		TunnelClientCertName: {pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644},
	}
	for name, file := range files {
		if err := atomicfile.Write(filepath.Join(root, name), file.contents, file.mode); err != nil {
			return err
		}
	}
	if err := writePrivateKey(filepath.Join(root, TunnelClientKeyName), clientKey); err != nil {
		return err
	}
	manifest := Manifest{
		Schema: Schema, InstallationID: material.InstallationID,
		ControlToken: ControlTokenName, FRPSToken: FRPSTokenName,
		TunnelCACertificate: TunnelCACertName, TunnelClientCert: TunnelClientCertName, TunnelClientKey: TunnelClientKeyName,
	}
	contents, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	return atomicfile.Write(filepath.Join(root, ManifestName), append(contents, '\n'), 0o600)
}

func decodeManifest(path string, output *Manifest) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("trailing bootstrap JSON")
	}
	return nil
}

func ReadNodeBundle(root string) (NodeBundle, error) {
	if !filepath.IsAbs(root) {
		return NodeBundle{}, errors.New("bootstrap path must be absolute")
	}
	root = filepath.Clean(root)
	var manifest Manifest
	if err := decodeManifest(filepath.Join(root, ManifestName), &manifest); err != nil {
		return NodeBundle{}, err
	}
	if manifest.Schema != Schema || !hex64.MatchString(manifest.InstallationID) ||
		manifest.ControlToken != ControlTokenName || manifest.FRPSToken != FRPSTokenName ||
		manifest.TunnelCACertificate != TunnelCACertName || manifest.TunnelClientCert != TunnelClientCertName || manifest.TunnelClientKey != TunnelClientKeyName {
		return NodeBundle{}, errors.New("invalid bootstrap manifest")
	}
	read := func(name string) ([]byte, error) { return os.ReadFile(filepath.Join(root, name)) }
	control, err := read(ControlTokenName)
	if err != nil {
		return NodeBundle{}, err
	}
	frps, err := read(FRPSTokenName)
	if err != nil {
		return NodeBundle{}, err
	}
	bundle := NodeBundle{InstallationID: manifest.InstallationID, ControlToken: strings.TrimRight(string(control), "\r\n"), FRPSToken: strings.TrimRight(string(frps), "\r\n")}
	if !hex64.MatchString(bundle.ControlToken) || !hex64.MatchString(bundle.FRPSToken) {
		return NodeBundle{}, errors.New("invalid bootstrap token")
	}
	bundle.CACertificate, err = read(TunnelCACertName)
	if err != nil {
		return NodeBundle{}, err
	}
	bundle.ClientCert, err = read(TunnelClientCertName)
	if err != nil {
		return NodeBundle{}, err
	}
	bundle.ClientKey, err = read(TunnelClientKeyName)
	if err != nil {
		return NodeBundle{}, err
	}
	ca, err := parseCertificate(bundle.CACertificate)
	if err != nil || validateTunnelCA(ca, bundle.InstallationID) != nil {
		return NodeBundle{}, errors.New("invalid bootstrap tunnel CA")
	}
	client, err := parseCertificate(bundle.ClientCert)
	if err != nil {
		return NodeBundle{}, err
	}
	if client.IsCA || client.Subject.CommonName != "remote-everything-tunnel-"+bundle.InstallationID || client.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return NodeBundle{}, errors.New("invalid tunnel client certificate")
	}
	key, err := parsePrivateKey(bundle.ClientKey)
	if err != nil || !publicKeysMatch(client, key) {
		return NodeBundle{}, errors.New("tunnel client key does not match certificate")
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	if _, err := client.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		return NodeBundle{}, errors.New("tunnel client certificate is not valid for bootstrap CA")
	}
	return bundle, nil
}

func Fingerprint(contents []byte) (string, error) {
	certificate, err := parseCertificate(contents)
	if err != nil {
		return "", err
	}
	value := sha256.Sum256(certificate.Raw)
	return hex.EncodeToString(value[:]), nil
}
