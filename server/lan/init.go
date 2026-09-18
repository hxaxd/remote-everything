package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"github.com/hxaxd/remote-everything/internal/netaddr"
	"github.com/hxaxd/remote-everything/internal/secret"
	"github.com/hxaxd/remote-everything/internal/tunnelbootstrap"
)

var (
	validDNSName            = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$`)
	validSHA256             = regexp.MustCompile(`^[a-f0-9]{64}$`)
	validLANCertificateFile = regexp.MustCompile(`^lan-server-[a-f0-9]{64}\.crt\.pem$`)
	validLANKeyFile         = regexp.MustCompile(`^lan-server-[a-f0-9]{64}\.key\.pem$`)
)

const (
	listenerName   = "lan"
	listenerPort   = 58626
	lanStateFile   = "lan.json"
	nodeTunnelHost = "127.0.0.1"
	nodeTunnelPort = 58628
)

// lanState is the LAN entrance's state: the same gateway state every entrance
// records, plus what only an entrance that fronts its own clients needs. It
// lives in the entrance's own root — the entrance is a service of its own, and
// the nodes it serves are separate services that may well be separate machines.
type lanState struct {
	gatewaycore.State
	LAN          lanCertificate   `json:"lan"`
	Applications []lanApplication `json:"applications"`
	// ApplicationsHost is where this entrance's applications listen: an address
	// of this machine, or the wildcard address, which is what an operator who
	// wants to open an application from the machine itself as much as from a
	// phone asks for. Empty means the entrance was told nothing, and then its
	// applications listen wherever the entrance itself listens.
	ApplicationsHost string `json:"applications_host"`
	RequireApproval  bool   `json:"require_approval,omitempty"`
}

// lanApplication is one application of one node as this entrance serves it: the
// port it answers on, which together with the host this entrance recorded is the
// whole of that application's origin. The port is recorded here rather than
// derived, because an application's origin is where a browser keeps everything it
// remembers about that application: an origin that moved between restarts would
// leave that behind, and the application would come back to itself empty.
type lanApplication struct {
	NodeID string `json:"node_id"`
	AppID  string `json:"app_id"`
	Port   int    `json:"port"`
}

// validPort is the shape of a port an application is served on: one this project
// allocates from, because a port below that is one an unprivileged process cannot
// hold in the first place.
func validPort(port int) bool {
	return port >= 1024 && port <= 65535
}

// lanCertificate is the half of the state that is LAN-specific: the TLS identity
// the entrance's clients pinned when they paired. The host its clients dial is
// the origin the shared state records, and the certificate this entrance serves
// is the one that origin's host has to resolve to. Where the nodes are is not
// here: each node carries its own address, because an entrance serves as many as
// it was given.
type lanCertificate struct {
	CertificateFingerprint string `json:"certificate_fingerprint"`
	CertificateFile        string `json:"certificate_file"`
	PrivateKeyFile         string `json:"private_key_file"`
}

// validLANHost is the shape an entrance's own host may have: the IPv4 address or
// the name clients reach it by, which is also what its certificate must cover.
func validLANHost(host string) bool {
	if host == "" {
		return false
	}
	ip := net.ParseIP(host)
	return (ip != nil && ip.To4() != nil) || (ip == nil && validDNSName.MatchString(host))
}

// host is the hostname or address this entrance serves and its certificate
// covers: the host half of the origin clients dial.
func (state lanState) host() (string, error) {
	parsed, err := url.Parse(state.Origin)
	if err != nil || parsed.Hostname() == "" {
		return "", errors.New("invalid LAN state")
	}
	return parsed.Hostname(), nil
}

// listener returns the address the entrance serves its clients on.
func (state lanState) listener() (string, error) {
	return state.Address(listenerName)
}

// applicationsHost is where this entrance's applications listen. An entrance that
// was told an address serves them there — an operator who wants to open an
// application from the machine itself says the wildcard address, and one who
// wants them nowhere else says the address the entrance is reached at — and an
// entrance that was told nothing serves them wherever it serves everything else.
func (state lanState) applicationsHost() (string, error) {
	if state.ApplicationsHost != "" {
		return state.ApplicationsHost, nil
	}
	listenAddress, err := state.listener()
	if err != nil {
		return "", err
	}
	host, _, err := net.SplitHostPort(listenAddress)
	if err != nil {
		return "", errors.New("invalid LAN state")
	}
	return host, nil
}

// repair moves the entrance's listener to a new port and keeps everything else.
func (state lanState) repair() (lanState, error) {
	shared, err := state.State.Repair(map[string]int{listenerName: listenerPort})
	if err != nil {
		return lanState{}, err
	}
	state.State = shared
	return state, nil
}

// ensureFRPS reserves and records an FRPS listener if one is not already present.
func (state *lanState) ensureFRPS() error {
	for _, l := range state.Listeners {
		if l.Name == "frps" {
			return nil
		}
	}
	address, err := state.AllocateNodeAddress("0.0.0.0", 58630)
	if err != nil {
		return err
	}
	state.Listeners = append(state.Listeners, gatewaycore.Listener{Name: "frps", Address: address})
	return state.Validate()
}

func (state lanState) save(root string) error {
	return jsonfile.Write(filepath.Join(root, lanStateFile), state, 0o600)
}

// validate checks the part of the state that only a LAN entrance has; the rest
// is checked by the shared gateway state, which also checks that each node sits
// at a concrete address this entrance can dial.
func (state lanState) validate() error {
	listenAddress, err := state.listener()
	if err != nil {
		return errors.New("invalid LAN state")
	}
	host, err := state.host()
	if err != nil {
		return err
	}
	_, port, _ := net.SplitHostPort(listenAddress)
	expectedOrigin := "https://" + net.JoinHostPort(host, port)
	expectedCertificate := "lan-server-" + state.LAN.CertificateFingerprint + ".crt.pem"
	expectedKey := "lan-server-" + state.LAN.CertificateFingerprint + ".key.pem"
	if !validLANHost(host) ||
		(state.ApplicationsHost != "" && !netaddr.ValidListenHost(state.ApplicationsHost)) ||
		!validSHA256.MatchString(state.LAN.CertificateFingerprint) ||
		state.Origin != expectedOrigin ||
		state.LAN.CertificateFile != expectedCertificate || state.LAN.PrivateKeyFile != expectedKey ||
		!validLANCertificateFile.MatchString(state.LAN.CertificateFile) || !validLANKeyFile.MatchString(state.LAN.PrivateKeyFile) {
		return errors.New("invalid LAN state")
	}
	// Each application is served on a port of its own, for a node this entrance
	// serves: two entries sharing a port would answer for each other, and an origin
	// for a node that is gone reaches nothing. Whether a node still runs an
	// application is not this state's to say — that belongs to that node, and this
	// entrance serves what it was opened for.
	seenApplications := map[string]bool{}
	seenApplicationPorts := map[int]bool{}
	for _, application := range state.Applications {
		if !validSHA256.MatchString(application.NodeID) || !gatewaycore.ValidAppID(application.AppID) || !validPort(application.Port) ||
			seenApplications[application.key()] || seenApplicationPorts[application.Port] {
			return errors.New("invalid LAN state")
		}
		if _, ok := state.FindNode(application.NodeID); !ok {
			return errors.New("invalid LAN state")
		}
		seenApplications[application.key()] = true
		seenApplicationPorts[application.Port] = true
	}
	return nil
}

type lanInitResult struct {
	OK                     bool   `json:"ok"`
	InstallationID         string `json:"installation_id"`
	ListenAddress          string `json:"listen_address"`
	Origin                 string `json:"origin"`
	CertificateFingerprint string `json:"certificate_fingerprint"`
	PublicKeyPin           string `json:"public_key_pin"`
	ApplicationsHost       string `json:"applications_host"`
	RequireApproval        bool   `json:"require_approval,omitempty"`
	FRPSListen             string `json:"frps_listen,omitempty"`
	FRPSTokenFile          string `json:"frps_token_file,omitempty"`
	TunnelCAFile           string `json:"tunnel_ca_file,omitempty"`
}

type lanNodeResult struct {
	OK                      bool   `json:"ok"`
	State                   string `json:"state"`
	NodeID                  string `json:"node_id"`
	NodeName                string `json:"node_name"`
	NodeAddress             string `json:"node_address"`
	NodeBootstrap           string `json:"node_bootstrap"`
	TunnelMaterialDir       string `json:"tunnel_material_directory,omitempty"`
	TunnelClientFingerprint string `json:"tunnel_client_fingerprint,omitempty"`
	RestartRequired         bool   `json:"restart_required"`
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

type lanNodeRemoveResult struct {
	OK              bool     `json:"ok"`
	State           string   `json:"state"`
	NodeID          string   `json:"node_id"`
	NodeName        string   `json:"node_name"`
	NodeAddress     string   `json:"node_address"`
	Devices         []string `json:"devices"`
	RestartRequired bool     `json:"restart_required"`
}

type lanTokenRenewResult struct {
	OK              bool   `json:"ok"`
	State           string `json:"state"`
	NodeID          string `json:"node_id"`
	NodeName        string `json:"node_name"`
	NodeAddress     string `json:"node_address"`
	NodeBootstrap   string `json:"node_bootstrap"`
	RestartRequired bool   `json:"restart_required"`
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
	serial, err := secret.Serial()
	if err != nil {
		return nil, nil, nil, err
	}
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

func repairLANPorts(root string) (lanInitResult, error) {
	state, err := loadLANState(root)
	if err != nil {
		return lanInitResult{}, err
	}
	certificate, err := loadLANCertificate(root, state)
	if err != nil {
		return lanInitResult{}, err
	}
	preferred := map[string]int{listenerName: listenerPort}
	if _, err := state.Address("frps"); err == nil {
		preferred["frps"] = 58630
	}
	repairedShared, err := state.State.Repair(preferred)
	if err != nil {
		return lanInitResult{}, err
	}
	state.State = repairedShared
	listenAddress, err := state.listener()
	if err != nil {
		return lanInitResult{}, err
	}
	// The port is part of the origin clients dial, so moving the port moves the
	// origin with it.
	_, port, _ := net.SplitHostPort(listenAddress)
	host, err := state.host()
	if err != nil {
		return lanInitResult{}, err
	}
	state.Origin = "https://" + net.JoinHostPort(host, port)
	if err := state.save(root); err != nil {
		return lanInitResult{}, err
	}
	frpsListen, _ := state.Address("frps")
	var frpsTokenFile, tunnelCAFile string
	if frpsListen != "" {
		frpsTokenFile = filepath.Join(root, tunnelbootstrap.FRPSTokenName)
		tunnelCAFile = filepath.Join(root, tunnelbootstrap.TunnelCACertName)
	}
	return lanInitResult{
		OK: true, InstallationID: state.InstallationID, ListenAddress: listenAddress,
		Origin: state.Origin, CertificateFingerprint: state.LAN.CertificateFingerprint,
		PublicKeyPin:     devicecore.PublicKeyPin(certificate),
		ApplicationsHost: state.ApplicationsHost,
		RequireApproval:  state.RequireApproval,
		FRPSListen:       frpsListen,
		FRPSTokenFile:    frpsTokenFile,
		TunnelCAFile:     tunnelCAFile,
	}, nil
}

func loadLANState(root string) (lanState, error) {
	if !filepath.IsAbs(root) {
		return lanState{}, errors.New("state path must be absolute")
	}
	root = filepath.Clean(root)
	var state lanState
	if err := jsonfile.Read(filepath.Join(root, lanStateFile), &state); err != nil {
		return lanState{}, err
	}
	if err := state.Validate(); err != nil {
		return lanState{}, err
	}
	if err := state.validate(); err != nil {
		return lanState{}, err
	}
	return state, nil
}

func lanCertificateNames(fingerprint string) (string, string) {
	return "lan-server-" + fingerprint + ".crt.pem", "lan-server-" + fingerprint + ".key.pem"
}

func writeLANCertificatePair(root string, certificate *x509.Certificate, certificatePEM, keyPEM []byte) (string, string, error) {
	fingerprint := devicecore.CertificateFingerprint(certificate)
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

func loadLANCertificate(root string, state lanState) (*x509.Certificate, error) {
	host, err := state.host()
	if err != nil {
		return nil, err
	}
	certificate, err := parseLANCertificate(filepath.Join(root, state.LAN.CertificateFile), filepath.Join(root, state.LAN.PrivateKeyFile), host)
	if err != nil {
		return nil, err
	}
	if devicecore.CertificateFingerprint(certificate) != state.LAN.CertificateFingerprint {
		return nil, errors.New("LAN certificate fingerprint does not match state")
	}
	return certificate, nil
}

type lanInitConfig struct {
	requireApproval bool
	tunnel          bool
}

// LANInitOption configures LAN initialization.
type LANInitOption func(*lanInitConfig)

// WithRequireApproval configures whether the gateway requires administrator approval
// for newly paired devices.
func WithRequireApproval(require bool) LANInitOption {
	return func(c *lanInitConfig) { c.requireApproval = require }
}

// WithTunnel configures whether the gateway allocates an FRPS tunnel listener and
// generates tunnel credentials.
func WithTunnel(tunnel bool) LANInitOption {
	return func(c *lanInitConfig) { c.tunnel = tunnel }
}

// reconcileLANState writes the state for an entrance that is being initialized.
// The entrance's own identity, host and certificate are what its clients were
// paired with, so they must be the ones already in place. Where its applications
// listen is the operator's to change — it is an address of this machine and not
// part of what a client was paired with — so being told one is what records it.
func reconcileLANState(root, host, applicationsHost, installationID, fingerprint, certificateFile, keyFile string, requireApproval, tunnel bool) (lanState, error) {
	state, err := loadLANState(root)
	if errors.Is(err, os.ErrNotExist) {
		// This entrance is what its clients dial, so its origin is its own host
		// and the port it just allocated.
		preferences := []gatewaycore.ListenerPreference{
			{Name: listenerName, Host: "0.0.0.0", PreferredPort: listenerPort},
		}
		if tunnel {
			preferences = append(preferences, gatewaycore.ListenerPreference{
				Name: "frps", Host: "0.0.0.0", PreferredPort: 58630,
			})
		}
		listeners, allocateErr := gatewaycore.AllocateListeners(preferences)
		if allocateErr != nil {
			return lanState{}, allocateErr
		}
		listenAddress, addressErr := gatewaycore.State{Listeners: listeners}.Address(listenerName)
		if addressErr != nil {
			return lanState{}, addressErr
		}
		_, port, _ := net.SplitHostPort(listenAddress)
		shared, stateErr := gatewaycore.NewState(installationID, "https://"+net.JoinHostPort(host, port), listeners)
		if stateErr != nil {
			return lanState{}, stateErr
		}
		state = lanState{
			State: shared,
			LAN: lanCertificate{
				CertificateFingerprint: fingerprint, CertificateFile: certificateFile, PrivateKeyFile: keyFile,
			},
			Applications:    []lanApplication{},
			RequireApproval: requireApproval,
		}
	} else if err != nil {
		return lanState{}, err
	} else if existingHost, hostErr := state.host(); hostErr != nil || existingHost != host || state.LAN.CertificateFingerprint != fingerprint || state.LAN.CertificateFile != certificateFile || state.LAN.PrivateKeyFile != keyFile {
		return lanState{}, errors.New("existing LAN state does not match host or certificate")
	} else {
		if requireApproval {
			state.RequireApproval = true
		}
		if tunnel {
			if err := state.ensureFRPS(); err != nil {
				return lanState{}, err
			}
		}
	}
	state.ApplicationsHost = applicationsHost
	if tunnel {
		if _, err := tunnelbootstrap.EnsureGatewayMaterial(root, installationID); err != nil {
			return lanState{}, err
		}
	}
	if err := jsonfile.Write(filepath.Join(root, lanStateFile), state, 0o600); err != nil {
		return lanState{}, err
	}
	return state, nil
}

func initializeLAN(root, host, applicationsHost string, validDays int, opts ...LANInitOption) (lanInitResult, error) {
	config := lanInitConfig{}
	for _, opt := range opts {
		opt(&config)
	}
	host = strings.TrimSpace(host)
	applicationsHost = strings.TrimSpace(applicationsHost)
	if !validLANHost(host) {
		return lanInitResult{}, errors.New("invalid LAN host")
	}
	if applicationsHost != "" && !netaddr.ValidListenHost(applicationsHost) {
		return lanInitResult{}, errors.New("invalid applications host")
	}
	if validDays < 1 || validDays > 3650 {
		return lanInitResult{}, errors.New("valid-days must be between 1 and 3650")
	}
	if !filepath.IsAbs(root) {
		return lanInitResult{}, errors.New("state path must be absolute")
	}
	// The state directory is this entrance's own, and the operator names it here
	// for the first time: it is created the way the other shapes create theirs,
	// rather than requiring a directory that does not exist yet.
	if err := os.MkdirAll(filepath.Clean(root), 0o700); err != nil {
		return lanInitResult{}, err
	}
	existing, stateErr := loadLANState(root)
	installationID := ""
	if stateErr == nil {
		existingHost, hostErr := existing.host()
		if hostErr != nil || existingHost != host {
			return lanInitResult{}, errors.New("existing LAN state serves another host")
		}
		installationID = existing.InstallationID
	} else if errors.Is(stateErr, os.ErrNotExist) {
		var secretErr error
		if installationID, secretErr = secret.Hex(32); secretErr != nil {
			return lanInitResult{}, secretErr
		}
	} else {
		return lanInitResult{}, stateErr
	}

	var err error
	var certificate *x509.Certificate
	var certificateFile, keyFile string
	createdCertificate := false
	if stateErr == nil {
		certificate, err = loadLANCertificate(root, existing)
		certificateFile, keyFile = existing.LAN.CertificateFile, existing.LAN.PrivateKeyFile
	} else {
		var certificatePEM, keyPEM []byte
		certificate, certificatePEM, keyPEM, err = generateLANCertificate(host, validDays)
		if err == nil {
			certificateFile, keyFile, err = writeLANCertificatePair(root, certificate, certificatePEM, keyPEM)
			createdCertificate = err == nil
		}
	}
	if err != nil {
		return lanInitResult{}, err
	}
	fingerprint := devicecore.CertificateFingerprint(certificate)
	state, err := reconcileLANState(root, host, applicationsHost, installationID, fingerprint, certificateFile, keyFile, config.requireApproval, config.tunnel)
	if err != nil {
		if createdCertificate {
			_ = os.Remove(filepath.Join(root, certificateFile))
			_ = os.Remove(filepath.Join(root, keyFile))
		}
		return lanInitResult{}, err
	}
	listenAddress, err := state.listener()
	if err != nil {
		return lanInitResult{}, err
	}
	applicationsListen, err := state.applicationsHost()
	if err != nil {
		return lanInitResult{}, err
	}
	frpsListen, _ := state.Address("frps")
	var frpsTokenFile, tunnelCAFile string
	if frpsListen != "" {
		frpsTokenFile = filepath.Join(root, tunnelbootstrap.FRPSTokenName)
		tunnelCAFile = filepath.Join(root, tunnelbootstrap.TunnelCACertName)
	}
	return lanInitResult{
		OK: true, InstallationID: state.InstallationID, ListenAddress: listenAddress, Origin: state.Origin,
		CertificateFingerprint: state.LAN.CertificateFingerprint, PublicKeyPin: devicecore.PublicKeyPin(certificate),
		// The address the applications listen on as it now stands, which is the
		// wildcard address until an operator says otherwise.
		ApplicationsHost: applicationsListen,
		RequireApproval:  state.RequireApproval,
		FRPSListen:       frpsListen,
		FRPSTokenFile:    frpsTokenFile,
		TunnelCAFile:     tunnelCAFile,
	}, nil
}

// addLANNode records one more node this entrance serves and hands its machine the
// identity bundle it binds this entrance with. Where the node is is the operator's
// to state: this entrance dials it at that address, so it is the address that
// machine listens on, and an entrance on another machine is told the one it can
// reach it at.
func addLANNode(root, name, nodeID, nodeAddress, bootstrapDir string) (lanNodeResult, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return lanNodeResult{}, errors.New("node bootstrap path must be absolute")
	}
	nodeID = strings.ToLower(strings.TrimSpace(nodeID))
	name = strings.TrimSpace(name)
	nodeAddress = strings.TrimSpace(nodeAddress)
	if !gatewaycore.ValidNodeName(name) {
		return lanNodeResult{}, errors.New("invalid node name")
	}
	state, err := loadLANState(root)
	if err != nil {
		return lanNodeResult{}, err
	}

	var tunnelMaterialDir, tunnelFingerprint string
	if nodeAddress != "" {
		if !netaddr.ValidUnicast(nodeAddress) {
			return lanNodeResult{}, errors.New("invalid node address")
		}
		added, err := gatewaycore.DeliverNode(root, state.State, gatewaycore.Node{ID: nodeID, Name: name, Address: nodeAddress}, bootstrapDir)
		if err != nil {
			return lanNodeResult{}, err
		}
		state.State = added
	} else {
		if err := state.ensureFRPS(); err != nil {
			return lanNodeResult{}, err
		}
		material, err := tunnelbootstrap.EnsureGatewayMaterial(root, state.InstallationID)
		if err != nil {
			return lanNodeResult{}, err
		}
		address := ""
		if existing, ok := state.FindNode(nodeID); ok {
			address = existing.Address
		} else if address, err = state.AllocateNodeAddress(nodeTunnelHost, nodeTunnelPort); err != nil {
			return lanNodeResult{}, err
		}
		nodeAddress = address
		added, err := gatewaycore.DeliverNode(root, state.State, gatewaycore.Node{ID: nodeID, Name: name, Address: nodeAddress}, bootstrapDir)
		if err != nil {
			return lanNodeResult{}, err
		}
		tunnel, err := tunnelbootstrap.EnsureTunnelMaterial(bootstrapDir, material)
		if err != nil {
			return lanNodeResult{}, err
		}
		tunnelMaterialDir = tunnel.Directory
		tunnelFingerprint = tunnel.Fingerprint
		state.State = added
	}

	if err := state.save(root); err != nil {
		return lanNodeResult{}, err
	}
	return lanNodeResult{
		OK: true, State: root, NodeID: nodeID, NodeName: name, NodeAddress: nodeAddress,
		NodeBootstrap: filepath.Clean(bootstrapDir), TunnelMaterialDir: tunnelMaterialDir,
		TunnelClientFingerprint: tunnelFingerprint, RestartRequired: true,
	}, nil
}

func renewLANTunnelIdentity(root, nodeBootstrap string) (tunnelRenewResult, error) {
	if !filepath.IsAbs(nodeBootstrap) {
		return tunnelRenewResult{}, errors.New("node bootstrap path must be absolute")
	}
	state, err := loadLANState(root)
	if err != nil {
		return tunnelRenewResult{}, err
	}
	material, err := tunnelbootstrap.EnsureGatewayMaterial(root, state.InstallationID)
	if err != nil {
		return tunnelRenewResult{}, err
	}
	tunnel, err := tunnelbootstrap.RenewTunnelMaterial(nodeBootstrap, material)
	if err != nil {
		return tunnelRenewResult{}, err
	}
	return tunnelRenewResult{
		OK: true, InstallationID: state.InstallationID,
		NodeBootstrap: filepath.Clean(nodeBootstrap), TunnelCAFile: material.CACertFile,
		TunnelIssuerDN:    material.CACertificate.Subject.String(),
		TunnelMaterialDir: tunnel.Directory, TunnelClientFingerprint: tunnel.Fingerprint,
	}, nil
}

// removeLANNode takes a node out of this entrance: it stops serving it, it stops
// reaching it, and nothing a device holds says it may reach it any more. What is
// left on that machine — the binding it imported — is the operator's to take down,
// and this entrance no longer has anything pointing at it. The origins its
// applications were served at go with it: a node this entrance does not serve has
// no application this entrance serves, and a mapping kept for one would be a state
// file that describes less than it did.
func removeLANNode(root, nodeValue string) (lanNodeRemoveResult, error) {
	service, err := openLANService(root)
	if err != nil {
		return lanNodeRemoveResult{}, err
	}
	node, err := gatewaycore.ResolveNode(service.state.Nodes, nodeValue)
	if err != nil {
		return lanNodeRemoveResult{}, err
	}
	reduced, err := service.state.RemoveNode(node.ID)
	if err != nil {
		return lanNodeRemoveResult{}, err
	}
	// The state goes first: a node the entrance no longer serves is unrouted at
	// once, and what is left behind by a failure — a device's list, a token file —
	// reaches nothing.
	service.state.State = reduced
	service.state.Applications = withoutApplicationsOf(service.state.Applications, node.ID)
	if err := service.state.save(root); err != nil {
		return lanNodeRemoveResult{}, err
	}
	devices, err := service.trust.ForgetNode(node.ID)
	if err != nil {
		return lanNodeRemoveResult{}, err
	}
	if err := gatewaycore.RemoveNodeToken(root, node.ID); err != nil {
		return lanNodeRemoveResult{}, fmt.Errorf("the node was removed, but its control token could not be deleted: %w", err)
	}
	return lanNodeRemoveResult{
		OK: true, State: root, NodeID: node.ID, NodeName: node.Name, NodeAddress: node.Address,
		Devices: devices, RestartRequired: true,
	}, nil
}

// renewLANNodeToken replaces the control token of a node this entrance serves and
// hands that machine the bundle carrying it. Which node it is, and where it is, do
// not change: this is for the machine that was given a token and should not have it
// any more.
func renewLANNodeToken(root, nodeValue, bootstrapDir string) (lanTokenRenewResult, error) {
	if !filepath.IsAbs(bootstrapDir) {
		return lanTokenRenewResult{}, errors.New("node bootstrap path must be absolute")
	}
	state, err := loadLANState(root)
	if err != nil {
		return lanTokenRenewResult{}, err
	}
	node, err := gatewaycore.ResolveNode(state.Nodes, nodeValue)
	if err != nil {
		return lanTokenRenewResult{}, err
	}
	// The state does not change — the node is the same node — so it is not written
	// again; what changes is the token, and the bundle that carries it.
	if _, err := gatewaycore.DeliverRotatedNode(root, state.State, node, bootstrapDir); err != nil {
		return lanTokenRenewResult{}, err
	}
	return lanTokenRenewResult{
		OK: true, State: root, NodeID: node.ID, NodeName: node.Name, NodeAddress: node.Address,
		NodeBootstrap: filepath.Clean(bootstrapDir), RestartRequired: true,
	}, nil
}

func runLANNode(parts []string, output io.Writer) error {
	if len(parts) == 0 {
		return errors.New("missing node action")
	}
	if len(parts) >= 2 && parts[0] == "token" && parts[1] == "renew" {
		return runLANNodeTokenRenew(parts[2:], output)
	}
	flags := flag.NewFlagSet("node "+parts[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	name := flags.String("name", "", "")
	nodeID := flags.String("node-id", "", "")
	node := flags.String("node", "", "")
	nodeAddress := flags.String("node-address", "", "")
	bootstrapDir := flags.String("node-bootstrap", "", "")
	if flags.Parse(parts[1:]) != nil || flags.NArg() != 0 {
		return errors.New("invalid node arguments")
	}
	switch parts[0] {
	case "add":
		if *name == "" || *nodeID == "" || *bootstrapDir == "" {
			return errors.New("invalid node add arguments")
		}
		result, err := addLANNode(*state, *name, *nodeID, *nodeAddress, *bootstrapDir)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(result)
	case "list":
		if *name != "" || *nodeID != "" || *node != "" || *nodeAddress != "" || *bootstrapDir != "" {
			return errors.New("invalid node list arguments")
		}
		stored, err := loadLANState(*state)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(stored.Nodes)
	case "remove":
		if *node == "" || *name != "" || *nodeID != "" || *nodeAddress != "" || *bootstrapDir != "" {
			return errors.New("invalid node remove arguments")
		}
		result, err := removeLANNode(*state, *node)
		if err != nil {
			return err
		}
		return json.NewEncoder(output).Encode(result)
	default:
		return errors.New("unknown node action")
	}
}

func runLANNodeTokenRenew(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("node token renew", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	node := flags.String("node", "", "")
	bootstrapDir := flags.String("node-bootstrap", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 || *node == "" || *bootstrapDir == "" {
		return errors.New("invalid node token renew arguments")
	}
	result, err := renewLANNodeToken(*state, *node, *bootstrapDir)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

// renewLANCertificate replaces the certificate this entrance serves with. What
// clients pinned was that certificate, so renewing it is what breaks them: the
// paired devices a client remembers are the credentials it still holds, but the
// gateway it dials is a new one and it has to be told so, with a new invitation.
func renewLANCertificate(root string, validDays int) (lanInitResult, error) {
	if validDays < 1 || validDays > 3650 {
		return lanInitResult{}, errors.New("invalid LAN certificate renewal arguments")
	}
	state, err := loadLANState(root)
	if err != nil {
		return lanInitResult{}, err
	}
	host, err := state.host()
	if err != nil {
		return lanInitResult{}, err
	}
	certificate, certificatePEM, keyPEM, err := generateLANCertificate(host, validDays)
	if err != nil {
		return lanInitResult{}, err
	}
	fingerprint := devicecore.CertificateFingerprint(certificate)
	keyPin := devicecore.PublicKeyPin(certificate)
	certificateFile, keyFile, err := writeLANCertificatePair(root, certificate, certificatePEM, keyPEM)
	if err != nil {
		return lanInitResult{}, err
	}
	oldCertificateFile, oldKeyFile := state.LAN.CertificateFile, state.LAN.PrivateKeyFile
	state.LAN.CertificateFingerprint = fingerprint
	state.LAN.CertificateFile = certificateFile
	state.LAN.PrivateKeyFile = keyFile
	if err := state.save(root); err != nil {
		_ = os.Remove(filepath.Join(root, certificateFile))
		_ = os.Remove(filepath.Join(root, keyFile))
		return lanInitResult{}, err
	}
	_ = os.Remove(filepath.Join(root, oldCertificateFile))
	_ = os.Remove(filepath.Join(root, oldKeyFile))
	listenAddress, err := state.listener()
	if err != nil {
		return lanInitResult{}, err
	}
	return lanInitResult{
		OK: true, InstallationID: state.InstallationID, ListenAddress: listenAddress, Origin: state.Origin,
		CertificateFingerprint: fingerprint, PublicKeyPin: keyPin,
	}, nil
}

func runLANInit(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("init", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	host := flags.String("host", "", "")
	applicationsHost := flags.String("applications-host", "", "")
	validDays := flags.Int("valid-days", 825, "")
	requireApproval := flags.Bool("require-approval", false, "")
	tunnel := flags.Bool("tunnel", false, "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 {
		return errors.New("invalid init arguments")
	}
	opts := []LANInitOption{}
	if *requireApproval {
		opts = append(opts, WithRequireApproval(true))
	}
	if *tunnel {
		opts = append(opts, WithTunnel(true))
	}
	result, err := initializeLAN(*state, *host, *applicationsHost, *validDays, opts...)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}

func runLANTunnelRenew(parts []string, output io.Writer) error {
	flags := flag.NewFlagSet("tunnel renew", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	state := flags.String("state", "", "")
	nodeBootstrap := flags.String("node-bootstrap", "", "")
	if flags.Parse(parts) != nil || flags.NArg() != 0 || *state == "" || *nodeBootstrap == "" {
		return errors.New("invalid tunnel renew arguments")
	}
	result, err := renewLANTunnelIdentity(*state, *nodeBootstrap)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
