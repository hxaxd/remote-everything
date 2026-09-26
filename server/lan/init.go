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
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/backplane/tunnelbootstrap"
	"github.com/hxaxd/remote-everything/internal/gateway/devicecore"
	"github.com/hxaxd/remote-everything/internal/gateway/entrance"
	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/infra/jsonfile"
	"github.com/hxaxd/remote-everything/internal/infra/netaddr"
	"github.com/hxaxd/remote-everything/internal/infra/secret"
	"github.com/hxaxd/remote-everything/internal/protocol/wire"
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
	nodeTunnelHost = tunnelbootstrap.NodeTunnelHost
	nodeTunnelPort = tunnelbootstrap.NodeTunnelPort
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

// ensureFRPS reserves and records an FRPS listener if one is not already present.
func (state *lanState) ensureFRPS() error {
	for _, l := range state.Listeners {
		if l.Name == "frps" {
			return nil
		}
	}
	address, err := state.AllocateNodeAddress("0.0.0.0", tunnelbootstrap.FRPSPort)
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
		if !validSHA256.MatchString(application.NodeID) || !wire.ValidAppID(application.AppID) || !validPort(application.Port) ||
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

// runLANNode runs the `node` command of this entrance's command line, which is
// the lifecycle every gateway shares over what only this shape contributes.
func runLANNode(parts []string, output io.Writer) error {
	return entrance.RunNode(parts, openLANNodes, output)
}

func runLANTunnelRenew(parts []string, output io.Writer) error {
	return entrance.RunTunnelRenew(parts, openLANNodes, output)
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
		preferred["frps"] = tunnelbootstrap.FRPSPort
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
		// Whether an invitation is the whole of the admission is the operator's
		// to state, and init is where they state it: saying nothing says it is
		// off, the same way being told no address says applications listen
		// wherever the entrance does.
		state.RequireApproval = requireApproval
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

// lanNodes is the LAN entrance's state as the node lifecycle sees it: the
// shape's part of the work every gateway shares.
type lanNodes struct {
	root  string
	state lanState
}

// openLANNodes opens the LAN entrance's state for a node command.
func openLANNodes(root string) (entrance.NodeShape, error) {
	return &lanNodes{root: root}, nil
}

func (nodes *lanNodes) State() (gatewaycore.State, error) {
	state, err := loadLANState(nodes.root)
	if err != nil {
		return gatewaycore.State{}, err
	}
	nodes.state = state
	return state.State, nil
}

func (nodes *lanNodes) Save(state gatewaycore.State) error {
	nodes.state.State = state
	return nodes.state.save(nodes.root)
}

func (nodes *lanNodes) Trust() (*devicecore.Trust, error) {
	state, err := loadLANState(nodes.root)
	if err != nil {
		return nil, err
	}
	gateway, err := gatewaycore.New(state.State, nodes.root)
	if err != nil {
		return nil, err
	}
	return openLANTrust(nodes.root, state, gateway)
}

// PlaceNode is where a node of this entrance lives: where the operator points
// — that machine's own address on the network — or, when they point nowhere,
// this entrance's own tunnel, whose listener is recorded with the node it
// serves.
func (nodes *lanNodes) PlaceNode(nodeID, address string) (gatewaycore.State, entrance.Placement, error) {
	if address != "" {
		if !netaddr.ValidUnicast(address) {
			return gatewaycore.State{}, entrance.Placement{}, errors.New("invalid node address")
		}
		return nodes.state.State, entrance.Placement{Address: address}, nil
	}
	if err := nodes.state.ensureFRPS(); err != nil {
		return gatewaycore.State{}, entrance.Placement{}, err
	}
	material, err := tunnelbootstrap.EnsureGatewayMaterial(nodes.root, nodes.state.InstallationID)
	if err != nil {
		return gatewaycore.State{}, entrance.Placement{}, err
	}
	// A node that is already here keeps the address it was added with: the
	// tunnel agent on its machine publishes that port, and moving it would
	// take the node out of reach until that machine is told.
	where := ""
	if existing, ok := nodes.state.FindNode(nodeID); ok {
		where = existing.Address
	} else if where, err = nodes.state.AllocateNodeAddress(nodeTunnelHost, nodeTunnelPort); err != nil {
		return gatewaycore.State{}, entrance.Placement{}, err
	}
	return nodes.state.State, entrance.Placement{Address: where, Tunnel: &material}, nil
}

// TookNodeAway takes the origins of the removed node's applications with it:
// a mapping kept for a node this entrance does not serve describes less than
// the state did.
func (nodes *lanNodes) TookNodeAway(nodeID string) error {
	nodes.state.Applications = withoutApplicationsOf(nodes.state.Applications, nodeID)
	return nil
}

// TunnelMaterial is this entrance's tunnel material. An entrance whose state
// records no tunnel listener has none, and says so rather than bringing one
// into existence.
func (nodes *lanNodes) TunnelMaterial() (tunnelbootstrap.GatewayMaterial, error) {
	state, err := loadLANState(nodes.root)
	if err != nil {
		return tunnelbootstrap.GatewayMaterial{}, err
	}
	if _, err := state.Address("frps"); err != nil {
		return tunnelbootstrap.GatewayMaterial{}, errors.New("this entrance has no tunnel")
	}
	return tunnelbootstrap.EnsureGatewayMaterial(nodes.root, state.InstallationID)
}

// addLANNode records one more node this entrance serves and hands its machine
// the identity bundle it binds this entrance with.
func addLANNode(root, name, nodeID, nodeAddress, link, bootstrapDir string) (entrance.NodeResult, error) {
	return entrance.AddNode(&lanNodes{root: root}, root, name, nodeID, nodeAddress, link, bootstrapDir)
}

// removeLANNode takes a node out of this entrance.
func removeLANNode(root, nodeValue string) (entrance.NodeRemoveResult, error) {
	return entrance.RemoveNode(&lanNodes{root: root}, root, nodeValue)
}

// renewLANNodeToken replaces the control token of a node this entrance serves
// and hands that machine the bundle carrying it.
func renewLANNodeToken(root, nodeValue, bootstrapDir string) (entrance.TokenRenewResult, error) {
	return entrance.RenewNodeToken(&lanNodes{root: root}, root, nodeValue, bootstrapDir)
}

// renewLANTunnelIdentity issues a fresh client identity for the tunnel into
// the handover bundle the operator already carries to the node machine.
func renewLANTunnelIdentity(root, nodeBootstrap string) (entrance.TunnelRenewResult, error) {
	return entrance.RenewTunnelIdentity(&lanNodes{root: root}, root, nodeBootstrap)
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
	opts := []LANInitOption{WithRequireApproval(*requireApproval)}
	if *tunnel {
		opts = append(opts, WithTunnel(true))
	}
	result, err := initializeLAN(*state, *host, *applicationsHost, *validDays, opts...)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(result)
}
