package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/deploymentbootstrap"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"github.com/hxaxd/remote-everything/internal/netaddr"
)

type publicInitResult struct {
	OK                      bool   `json:"ok"`
	State                   string `json:"state"`
	InstallationID          string `json:"installation_id"`
	ControlTokenFile        string `json:"control_token_file"`
	DeviceCAFile            string `json:"device_ca_file"`
	StatusListen            string `json:"status_listen"`
	PairingListen           string `json:"pairing_listen"`
	FRPSListen              string `json:"frps_listen"`
	NodeTunnelListen        string `json:"node_tunnel_listen"`
	NodeBootstrap           string `json:"node_bootstrap"`
	FRPSTokenFile           string `json:"frps_token_file"`
	TunnelCAFile            string `json:"tunnel_ca_file"`
	TunnelMaterialDir       string `json:"tunnel_material_directory"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	DeviceIssuerDN          string `json:"device_issuer_dn"`
	TunnelIssuerDN          string `json:"tunnel_issuer_dn"`
}

type tunnelRenewResult struct {
	OK                      bool   `json:"ok"`
	InstallationID          string `json:"installation_id"`
	NodeBootstrap           string `json:"node_bootstrap"`
	TunnelCAFile            string `json:"tunnel_ca_file"`
	TunnelMaterialDir       string `json:"tunnel_material_directory"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint"`
	TunnelIssuerDN          string `json:"tunnel_issuer_dn"`
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

// allocatePublicAddresses reserves the four distinct loopback addresses the
// public gateway listens on, in the order status, pairing, frps, node tunnel.
func allocatePublicAddresses() ([4]string, error) {
	preferred := []int{58629, 58631, 58630, 58628}
	var addresses [4]string
	seen := map[string]bool{}
	for index, port := range preferred {
		for attempt := 0; attempt < 16 && addresses[index] == ""; attempt++ {
			candidate, err := netaddr.Reserve("127.0.0.1", port)
			if err != nil {
				return addresses, err
			}
			if !seen[candidate] {
				addresses[index] = candidate
				seen[candidate] = true
				continue
			}
			port = 0
		}
		if addresses[index] == "" {
			return addresses, errors.New("no public loopback port available")
		}
	}
	return addresses, nil
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
		installationID, randomErr := gatewaycore.NewSecret()
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
	controlToken, err := gatewaycore.EnsureControlToken(paths.root)
	if err != nil {
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
		if err := jsonfile.Write(paths.stateFile, state, 0o600); err != nil {
			return publicInitResult{}, err
		}
	}
	material, err := deploymentbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID, controlToken)
	if err != nil {
		return publicInitResult{}, err
	}
	identity := gatewaycore.Identity{InstallationID: state.InstallationID, ControlToken: controlToken}
	if err := identity.WriteBundle(nodeBootstrap); err != nil {
		return publicInitResult{}, err
	}
	tunnel, err := deploymentbootstrap.EnsureTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return publicInitResult{}, err
	}
	return publicInitResult{
		OK: true, State: paths.root, InstallationID: state.InstallationID,
		ControlTokenFile: gatewaycore.ControlTokenPath(paths.root), DeviceCAFile: paths.issuerCertFile,
		StatusListen: state.StatusListen, PairingListen: state.PairingListen,
		FRPSListen: state.FRPSListen, NodeTunnelListen: state.NodeTunnelListen,
		NodeBootstrap: filepath.Clean(nodeBootstrap), FRPSTokenFile: material.FRPSTokenFile, TunnelCAFile: material.CACertFile,
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
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

// renewTunnelIdentity issues a new client identity for the tunnel into the
// handover bundle the operator already carries to the node machine. The node
// takes no part in it: neither the identity the gateway is bound by nor the
// tunnel CA changes, so only the tunnel agent has to be pointed at the newly
// delivered files and restarted.
func renewTunnelIdentity(root, nodeBootstrap string, output io.Writer) error {
	paths, err := newPublicPaths(root)
	if err != nil {
		return err
	}
	state, err := paths.loadState()
	if err != nil {
		return err
	}
	controlToken, err := gatewaycore.ReadControlToken(paths.root)
	if err != nil {
		return err
	}
	material, err := deploymentbootstrap.EnsureGatewayMaterial(paths.root, state.InstallationID, controlToken)
	if err != nil {
		return err
	}
	tunnel, err := deploymentbootstrap.RenewTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(tunnelRenewResult{
		OK: true, InstallationID: state.InstallationID,
		NodeBootstrap: filepath.Clean(nodeBootstrap), TunnelCAFile: material.CACertFile,
		TunnelIssuerDN:    material.CACertificate.Subject.String(),
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
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
		ControlTokenFile: gatewaycore.ControlTokenPath(paths.root), DeviceCAFile: paths.issuerCertFile,
		StatusListen: state.StatusListen, PairingListen: state.PairingListen,
		FRPSListen: state.FRPSListen, NodeTunnelListen: state.NodeTunnelListen,
	})
}
