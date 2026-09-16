package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
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
	"strconv"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
)

type publicInitResult struct {
	OK               bool   `json:"ok"`
	State            string `json:"state"`
	InstallationID   string `json:"installation_id"`
	ControlTokenFile string `json:"control_token_file"`
	DeviceCAFile     string `json:"device_ca_file"`
	StatusListen     string `json:"status_listen"`
	PairingListen    string `json:"pairing_listen"`
	FRPSListen       string `json:"frps_listen"`
	NodeTunnelListen string `json:"node_tunnel_listen"`
	NodeBootstrap    string `json:"node_bootstrap"`
	FRPSTokenFile    string `json:"frps_token_file"`
	TunnelCAFile     string `json:"tunnel_ca_file"`
	TunnelClientCert string `json:"tunnel_client_certificate_file"`
	TunnelClientKey  string `json:"tunnel_client_key_file"`
	DeviceIssuerDN   string `json:"device_issuer_dn"`
	TunnelIssuerDN   string `json:"tunnel_issuer_dn"`
}

type tunnelRenewResult struct {
	OK                      bool   `json:"ok"`
	InstallationID          string `json:"installation_id"`
	TunnelCAFile            string `json:"tunnel_ca_file"`
	TunnelClientCert        string `json:"tunnel_client_certificate_file"`
	TunnelClientKey         string `json:"tunnel_client_key_file"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	TunnelIssuerDN          string `json:"tunnel_issuer_dn"`
}

func randomHex(size int) (string, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}

func initializeControlToken(paths publicPaths) error {
	existing, err := os.ReadFile(paths.controlTokenFile)
	if err == nil {
		token := strings.TrimSpace(string(existing))
		if !validHex64.MatchString(token) {
			return errors.New("invalid existing control token")
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	requested, err := randomHex(32)
	if err != nil {
		return err
	}
	return atomicfile.Write(paths.controlTokenFile, []byte(requested+"\n"), 0o600)
}

func initializeIssuer(paths publicPaths) error {
	keyExists := false
	if _, err := os.Stat(paths.issuerKeyFile); err == nil {
		keyExists = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	certExists := false
	if _, err := os.Stat(paths.issuerCertFile); err == nil {
		certExists = true
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if keyExists || certExists {
		if !keyExists || !certExists {
			return errors.New("incomplete device issuer material")
		}
		_, _, err := loadIssuer(paths)
		return err
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serialBytes := make([]byte, 20)
	if _, err := rand.Read(serialBytes); err != nil {
		return err
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
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return err
	}
	if err := atomicfile.Write(paths.issuerKeyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		return err
	}
	if err := atomicfile.Write(paths.issuerCertFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certificateDER}), 0o644); err != nil {
		return err
	}
	_, _, err = loadIssuer(paths)
	return err
}

func allocatePublicAddresses() ([4]string, error) {
	preferred := []int{58629, 58631, 58630, 58628}
	var result [4]string
	seen := map[string]bool{}
	for index, port := range preferred {
		for attempt := 0; attempt < 16; attempt++ {
			candidate := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
			if attempt > 0 {
				candidate = "127.0.0.1:0"
			}
			listener, err := net.Listen("tcp4", candidate)
			if err != nil {
				continue
			}
			address := listener.Addr().String()
			closeErr := listener.Close()
			if closeErr != nil {
				return result, closeErr
			}
			if validPublicLoopback(address) && !seen[address] {
				result[index] = address
				seen[address] = true
				break
			}
		}
		if result[index] == "" {
			return result, errors.New("no public loopback port available")
		}
	}
	return result, nil
}

func initializePublicState(root, nodeBootstrap string) (publicInitResult, error) {
	if !filepath.IsAbs(nodeBootstrap) {
		return publicInitResult{}, errors.New("node bootstrap path must be absolute")
	}
	paths, err := newPublicPaths(root)
	if err != nil {
		return publicInitResult{}, err
	}
	if err := os.MkdirAll(paths.devicesDir, 0o700); err != nil {
		return publicInitResult{}, err
	}
	if err := os.MkdirAll(paths.invitesDir, 0o700); err != nil {
		return publicInitResult{}, err
	}
	state, err := paths.loadState()
	newState := errors.Is(err, os.ErrNotExist)
	if newState {
		installationID, randomErr := randomHex(32)
		if randomErr != nil {
			return publicInitResult{}, randomErr
		}
		addresses, allocateErr := allocatePublicAddresses()
		if allocateErr != nil {
			return publicInitResult{}, allocateErr
		}
		state = publicState{
			Schema: publicStateSchema, InstallationID: installationID,
			StatusListen: addresses[0], PairingListen: addresses[1], FRPSListen: addresses[2], NodeTunnelListen: addresses[3],
		}
	} else if err != nil {
		return publicInitResult{}, err
	}
	if err := initializeControlToken(paths); err != nil {
		return publicInitResult{}, err
	}
	if err := initializeIssuer(paths); err != nil {
		return publicInitResult{}, err
	}
	_, deviceIssuer, err := loadIssuer(paths)
	if err != nil {
		return publicInitResult{}, err
	}
	if newState {
		contents, marshalErr := json.Marshal(state)
		if marshalErr != nil {
			return publicInitResult{}, marshalErr
		}
		if err := atomicfile.Write(paths.stateFile, append(contents, '\n'), 0o600); err != nil {
			return publicInitResult{}, err
		}
	}
	controlTokenContents, err := os.ReadFile(paths.controlTokenFile)
	if err != nil {
		return publicInitResult{}, err
	}
	controlToken := strings.TrimSpace(string(controlTokenContents))
	material, err := deploymentbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID, controlToken)
	if err != nil {
		return publicInitResult{}, err
	}
	tunnelIdentity, err := deploymentbootstrap.EnsureTunnelClientIdentity(paths.root, material)
	if err != nil {
		return publicInitResult{}, err
	}
	if err := deploymentbootstrap.WriteNodeBundle(nodeBootstrap, state.InstallationID, controlToken); err != nil {
		return publicInitResult{}, err
	}
	return publicInitResult{
		OK: true, State: paths.root, InstallationID: state.InstallationID,
		ControlTokenFile: paths.controlTokenFile, DeviceCAFile: paths.issuerCertFile,
		StatusListen: state.StatusListen, PairingListen: state.PairingListen,
		FRPSListen: state.FRPSListen, NodeTunnelListen: state.NodeTunnelListen,
		NodeBootstrap: filepath.Clean(nodeBootstrap), FRPSTokenFile: material.FRPSTokenFile, TunnelCAFile: material.CACertFile,
		TunnelClientCert: tunnelIdentity.CertificateFile, TunnelClientKey: tunnelIdentity.KeyFile,
		DeviceIssuerDN: deviceIssuer.Subject.String(), TunnelIssuerDN: material.CACertificate.Subject.String(),
	}, nil
}

func runPublicInit(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	nodeBootstrap := flags.String("node-bootstrap", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 {
		return errors.New("invalid init arguments")
	}
	result, err := initializePublicState(*state, *nodeBootstrap)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

// renewTunnelIdentity rotates the tunnel client identity the gateway issues.
// The node takes no part in it: the identity the gateway is bound by does not
// change, so renewal is entirely a gateway-side operation.
func renewTunnelIdentity(root string, output io.Writer) error {
	paths, err := newPublicPaths(root)
	if err != nil {
		return err
	}
	state, err := paths.loadState()
	if err != nil {
		return err
	}
	controlToken, err := os.ReadFile(paths.controlTokenFile)
	if err != nil {
		return err
	}
	material, err := deploymentbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID, strings.TrimSpace(string(controlToken)))
	if err != nil {
		return err
	}
	identity, err := deploymentbootstrap.RenewTunnelClientIdentity(paths.root, material)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(tunnelRenewResult{
		OK: true, InstallationID: state.InstallationID,
		TunnelCAFile: material.CACertFile, TunnelIssuerDN: material.CACertificate.Subject.String(),
		TunnelClientCert: identity.CertificateFile, TunnelClientKey: identity.KeyFile,
		TunnelClientFingerprint: identity.Fingerprint,
	})
}

func repairPublicPorts(root string, output io.Writer) error {
	paths, err := newPublicPaths(root)
	if err != nil {
		return err
	}
	state, err := paths.loadState()
	if err != nil {
		return err
	}
	addresses, err := allocatePublicAddresses()
	if err != nil {
		return err
	}
	state.StatusListen = addresses[0]
	state.PairingListen = addresses[1]
	state.FRPSListen = addresses[2]
	state.NodeTunnelListen = addresses[3]
	contents, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if err := atomicfile.Write(paths.stateFile, append(contents, '\n'), 0o600); err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(publicInitResult{
		OK: true, State: paths.root, InstallationID: state.InstallationID,
		ControlTokenFile: paths.controlTokenFile, DeviceCAFile: paths.issuerCertFile,
		StatusListen: state.StatusListen, PairingListen: state.PairingListen,
		FRPSListen: state.FRPSListen, NodeTunnelListen: state.NodeTunnelListen,
	})
}
