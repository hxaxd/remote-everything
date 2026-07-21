package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/nodecore"
	setupcodec "github.com/hxaxd/remote-everything/internal/setup"
)

const lanStateSchema = 1

var (
	validDNSName            = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
	validSHA256             = regexp.MustCompile(`^[a-f0-9]{64}$`)
	validLANCertificateFile = regexp.MustCompile(`^lan-server-[a-f0-9]{64}\.crt\.pem$`)
	validLANKeyFile         = regexp.MustCompile(`^lan-server-[a-f0-9]{64}\.key\.pem$`)
)

type lanState struct {
	Schema                 int    `json:"schema"`
	InstallationID         string `json:"installation_id"`
	ListenAddress          string `json:"listen_address"`
	Host                   string `json:"host"`
	GatewayOrigin          string `json:"gateway_origin"`
	CertificateFingerprint string `json:"certificate_fingerprint"`
	CertificateFile        string `json:"certificate_file"`
	PrivateKeyFile         string `json:"private_key_file"`
}

type lanInitResult struct {
	OK                     bool   `json:"ok"`
	InstallationID         string `json:"installation_id"`
	ListenAddress          string `json:"listen_address"`
	GatewayOrigin          string `json:"gateway_origin"`
	CertificateFingerprint string `json:"certificate_fingerprint"`
	PublicKeyPin           string `json:"public_key_pin"`
	SetupURI               string `json:"setup_uri,omitempty"`
	QRFile                 string `json:"qr_file,omitempty"`
}

func lanPublicKeyPin(certificate *x509.Certificate) string {
	digest := sha256.Sum256(certificate.RawSubjectPublicKeyInfo)
	return base64.StdEncoding.EncodeToString(digest[:])
}

func writeNewFile(path string, contents []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := file.Write(contents); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return err
	}
	return file.Close()
}

func parseLANCertificate(certificateFile, keyFile, host string) (*x509.Certificate, error) {
	pair, err := tls.LoadX509KeyPair(certificateFile, keyFile)
	if err != nil || len(pair.Certificate) == 0 {
		return nil, errors.New("invalid LAN TLS material")
	}
	certificate, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, err
	}
	if err := certificate.VerifyHostname(host); err != nil {
		return nil, errors.New("LAN certificate does not cover the requested host")
	}
	if time.Now().Before(certificate.NotBefore) || time.Now().After(certificate.NotAfter) {
		return nil, errors.New("LAN certificate is not currently valid")
	}
	return certificate, nil
}

func generateLANCertificate(host string, validDays int) (*x509.Certificate, []byte, []byte, error) {
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, err
	}
	serialBytes := make([]byte, 20)
	if _, err := rand.Read(serialBytes); err != nil {
		return nil, nil, nil, err
	}
	serial := new(big.Int).SetBytes(serialBytes)
	serial.Rsh(serial, 1)
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "Remote Everything LAN"},
		NotBefore: now.Add(-5 * time.Minute), NotAfter: now.Add(time.Duration(validDays) * 24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true,
	}
	ip := net.ParseIP(host)
	if ip != nil {
		template.IPAddresses = []net.IP{ip}
	} else {
		template.DNSNames = []string{host}
	}
	certificateDER, err := x509.CreateCertificate(rand.Reader, template, template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return nil, nil, nil, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, nil, nil, err
	}
	certificate, err := x509.ParseCertificate(certificateDER)
	if err != nil {
		return nil, nil, nil, err
	}
	return certificate,
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), nil
}

func allocateLANAddress() (string, error) {
	for _, address := range []string{"0.0.0.0:58626", "0.0.0.0:0"} {
		listener, err := net.Listen("tcp4", address)
		if err != nil {
			continue
		}
		port := listener.Addr().(*net.TCPAddr).Port
		if closeErr := listener.Close(); closeErr != nil {
			return "", closeErr
		}
		if port >= 1024 {
			return net.JoinHostPort("0.0.0.0", strconv.Itoa(port)), nil
		}
	}
	return "", errors.New("no LAN port available")
}

func repairLANPorts(root string) (lanInitResult, error) {
	if !filepath.IsAbs(root) {
		return lanInitResult{}, errors.New("state path must be absolute")
	}
	root = filepath.Clean(root)
	state, err := loadLANState(root)
	if err != nil {
		return lanInitResult{}, err
	}
	certificate, err := loadLANCertificate(root, state.Host, state)
	if err != nil {
		return lanInitResult{}, err
	}
	state.ListenAddress, err = allocateLANAddress()
	if err != nil {
		return lanInitResult{}, err
	}
	_, port, _ := net.SplitHostPort(state.ListenAddress)
	state.GatewayOrigin = "https://" + net.JoinHostPort(state.Host, port)
	contents, err := json.Marshal(state)
	if err != nil {
		return lanInitResult{}, err
	}
	if err := atomicfile.Write(filepath.Join(root, "lan.json"), append(contents, '\n'), 0o600); err != nil {
		return lanInitResult{}, err
	}
	return lanInitResult{
		OK: true, InstallationID: state.InstallationID, ListenAddress: state.ListenAddress,
		GatewayOrigin: state.GatewayOrigin, CertificateFingerprint: state.CertificateFingerprint,
		PublicKeyPin: lanPublicKeyPin(certificate),
	}, nil
}

func loadLANState(root string) (lanState, error) {
	file, err := os.Open(filepath.Join(root, "lan.json"))
	if err != nil {
		return lanState{}, err
	}
	defer file.Close()
	var state lanState
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return lanState{}, err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return lanState{}, errors.New("trailing JSON content")
	}
	host, port, err := net.SplitHostPort(state.ListenAddress)
	portNumber, portErr := strconv.Atoi(port)
	expectedOrigin := "https://" + net.JoinHostPort(state.Host, port)
	expectedCertificate := "lan-server-" + state.CertificateFingerprint + ".crt.pem"
	expectedKey := "lan-server-" + state.CertificateFingerprint + ".key.pem"
	if err != nil || portErr != nil || portNumber < 1024 || portNumber > 65535 || host != "0.0.0.0" || state.Schema != lanStateSchema || !validSHA256.MatchString(state.InstallationID) || state.Host == "" || !validSHA256.MatchString(state.CertificateFingerprint) || state.GatewayOrigin != expectedOrigin || !validLANCertificateFile.MatchString(state.CertificateFile) || !validLANKeyFile.MatchString(state.PrivateKeyFile) || state.CertificateFile != expectedCertificate || state.PrivateKeyFile != expectedKey {
		return lanState{}, errors.New("invalid LAN state")
	}
	return state, nil
}

func lanCertificateNames(fingerprint string) (string, string) {
	return "lan-server-" + fingerprint + ".crt.pem", "lan-server-" + fingerprint + ".key.pem"
}

func writeLANCertificatePair(root string, certificate *x509.Certificate, certificatePEM, keyPEM []byte) (string, string, error) {
	fingerprintBytes := sha256.Sum256(certificate.Raw)
	fingerprint := hex.EncodeToString(fingerprintBytes[:])
	certificateName, keyName := lanCertificateNames(fingerprint)
	certificatePath := filepath.Join(root, certificateName)
	keyPath := filepath.Join(root, keyName)
	if err := writeNewFile(keyPath, keyPEM, 0o600); err != nil {
		return "", "", err
	}
	if err := writeNewFile(certificatePath, certificatePEM, 0o644); err != nil {
		_ = os.Remove(keyPath)
		return "", "", err
	}
	return certificateName, keyName, nil
}

func loadLANCertificate(root, host string, state lanState) (*x509.Certificate, error) {
	certificate, err := parseLANCertificate(filepath.Join(root, state.CertificateFile), filepath.Join(root, state.PrivateKeyFile), host)
	if err != nil {
		return nil, err
	}
	fingerprintBytes := sha256.Sum256(certificate.Raw)
	if hex.EncodeToString(fingerprintBytes[:]) != state.CertificateFingerprint {
		return nil, errors.New("LAN certificate fingerprint does not match state")
	}
	return certificate, nil
}

func reconcileLANState(root, host, installationID, fingerprint, certificateFile, keyFile string) (lanState, error) {
	state, err := loadLANState(root)
	if errors.Is(err, os.ErrNotExist) {
		listenAddress, allocateErr := allocateLANAddress()
		if allocateErr != nil {
			return lanState{}, allocateErr
		}
		_, port, _ := net.SplitHostPort(listenAddress)
		state = lanState{
			Schema: lanStateSchema, InstallationID: installationID, ListenAddress: listenAddress, Host: host,
			GatewayOrigin: "https://" + net.JoinHostPort(host, port), CertificateFingerprint: fingerprint,
			CertificateFile: certificateFile, PrivateKeyFile: keyFile,
		}
		contents, marshalErr := json.Marshal(state)
		if marshalErr != nil {
			return lanState{}, marshalErr
		}
		if err := atomicfile.Write(filepath.Join(root, "lan.json"), append(contents, '\n'), 0o600); err != nil {
			return lanState{}, err
		}
		return state, nil
	}
	if err != nil {
		return lanState{}, err
	}
	if state.InstallationID != installationID || state.Host != host || state.CertificateFingerprint != fingerprint || state.CertificateFile != certificateFile || state.PrivateKeyFile != keyFile {
		return lanState{}, errors.New("existing LAN state does not match node or host")
	}
	return state, nil
}

func initializeLAN(root, host string, validDays int) (lanInitResult, error) {
	if !filepath.IsAbs(root) {
		return lanInitResult{}, errors.New("state path must be absolute")
	}
	host = strings.TrimSpace(host)
	ip := net.ParseIP(host)
	if host == "" || (ip != nil && ip.To4() == nil) || (ip == nil && !validDNSName.MatchString(host)) {
		return lanInitResult{}, errors.New("invalid LAN host")
	}
	if validDays < 1 || validDays > 3650 {
		return lanInitResult{}, errors.New("valid-days must be between 1 and 3650")
	}
	root = filepath.Clean(root)
	nodeState, err := nodecore.LoadState(root)
	if err != nil {
		return lanInitResult{}, errors.New("initialize the node state first")
	}
	token, err := os.ReadFile(filepath.Join(root, "control-token"))
	if err != nil {
		return lanInitResult{}, errors.New("node control token unavailable")
	}
	if _, err := gatewaycore.New("http://"+nodeState.ListenAddress, string(token)); err != nil {
		return lanInitResult{}, err
	}

	existing, stateErr := loadLANState(root)
	var certificate *x509.Certificate
	var certificateFile, keyFile string
	createdCertificate := false
	if stateErr == nil {
		if existing.InstallationID != nodeState.InstallationID || existing.Host != host {
			return lanInitResult{}, errors.New("existing LAN state does not match node or host")
		}
		certificate, err = loadLANCertificate(root, host, existing)
		certificateFile, keyFile = existing.CertificateFile, existing.PrivateKeyFile
	} else if errors.Is(stateErr, os.ErrNotExist) {
		var certificatePEM, keyPEM []byte
		certificate, certificatePEM, keyPEM, err = generateLANCertificate(host, validDays)
		if err == nil {
			certificateFile, keyFile, err = writeLANCertificatePair(root, certificate, certificatePEM, keyPEM)
			createdCertificate = err == nil
		}
	} else {
		return lanInitResult{}, stateErr
	}
	if err != nil {
		return lanInitResult{}, err
	}
	fingerprintBytes := sha256.Sum256(certificate.Raw)
	fingerprint := hex.EncodeToString(fingerprintBytes[:])
	state, err := reconcileLANState(root, host, nodeState.InstallationID, fingerprint, certificateFile, keyFile)
	if err != nil {
		if createdCertificate {
			_ = os.Remove(filepath.Join(root, certificateFile))
			_ = os.Remove(filepath.Join(root, keyFile))
		}
		return lanInitResult{}, err
	}
	return lanInitResult{
		OK: true, InstallationID: state.InstallationID, ListenAddress: state.ListenAddress,
		GatewayOrigin: state.GatewayOrigin, CertificateFingerprint: state.CertificateFingerprint,
		PublicKeyPin: lanPublicKeyPin(certificate),
	}, nil
}

func renewLANCertificate(root string, validDays int, name, qrFile string) (lanInitResult, error) {
	if !filepath.IsAbs(root) || validDays < 1 || validDays > 3650 || strings.TrimSpace(name) == "" {
		return lanInitResult{}, errors.New("invalid LAN certificate renewal arguments")
	}
	root = filepath.Clean(root)
	state, err := loadLANState(root)
	if err != nil {
		return lanInitResult{}, err
	}
	node, err := nodecore.LoadState(root)
	if err != nil || node.InstallationID != state.InstallationID {
		return lanInitResult{}, errors.New("node state does not match LAN installation")
	}
	certificate, certificatePEM, keyPEM, err := generateLANCertificate(state.Host, validDays)
	if err != nil {
		return lanInitResult{}, err
	}
	fingerprintBytes := sha256.Sum256(certificate.Raw)
	fingerprint := hex.EncodeToString(fingerprintBytes[:])
	keyPin := lanPublicKeyPin(certificate)
	setupURI, err := setupcodec.Build("lan", state.InstallationID, name, state.GatewayOrigin, fingerprint, keyPin)
	if err != nil {
		return lanInitResult{}, err
	}
	if err := setupcodec.WriteQR(qrFile, setupURI); err != nil {
		return lanInitResult{}, err
	}
	certificateFile, keyFile, err := writeLANCertificatePair(root, certificate, certificatePEM, keyPEM)
	if err != nil {
		return lanInitResult{}, err
	}
	oldCertificateFile, oldKeyFile := state.CertificateFile, state.PrivateKeyFile
	state.CertificateFingerprint = fingerprint
	state.CertificateFile = certificateFile
	state.PrivateKeyFile = keyFile
	contents, err := json.Marshal(state)
	if err != nil {
		_ = os.Remove(filepath.Join(root, certificateFile))
		_ = os.Remove(filepath.Join(root, keyFile))
		return lanInitResult{}, err
	}
	if err := atomicfile.Write(filepath.Join(root, "lan.json"), append(contents, '\n'), 0o600); err != nil {
		_ = os.Remove(filepath.Join(root, certificateFile))
		_ = os.Remove(filepath.Join(root, keyFile))
		return lanInitResult{}, err
	}
	_ = os.Remove(filepath.Join(root, oldCertificateFile))
	_ = os.Remove(filepath.Join(root, oldKeyFile))
	return lanInitResult{
		OK: true, InstallationID: state.InstallationID, ListenAddress: state.ListenAddress, GatewayOrigin: state.GatewayOrigin,
		CertificateFingerprint: fingerprint, SetupURI: setupURI, QRFile: qrFile,
		PublicKeyPin: keyPin,
	}, nil
}

func runLANInit(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	host := flags.String("host", "", "")
	validDays := flags.Int("valid-days", 825, "")
	name := flags.String("name", "", "")
	qrFile := flags.String("qr", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 || strings.TrimSpace(*name) == "" {
		return errors.New("invalid init arguments")
	}
	result, err := initializeLAN(*state, *host, *validDays)
	if err != nil {
		return err
	}
	setupURI, err := setupcodec.Build("lan", result.InstallationID, *name, result.GatewayOrigin, result.CertificateFingerprint, result.PublicKeyPin)
	if err != nil {
		return err
	}
	if err := setupcodec.WriteQR(*qrFile, setupURI); err != nil {
		return err
	}
	result.SetupURI = setupURI
	result.QRFile = *qrFile
	return json.NewEncoder(output).Encode(result)
}
