// Package entrancetest is the behaviour every gateway shape must show, written
// once and run against each shape.
//
// The two shapes differ in where TLS ends and in what their init creates. They
// must not differ in what a client sees: an entrance that authenticates its own
// clients and one standing behind an entrance that authenticates them answer the
// same requests the same way, admit the same devices, and refuse the same ones.
// That is a property of the protocol rather than of either implementation, so it
// is stated once here and each shape adapts itself to it — a shape that drifts
// fails this suite, and so does the shape it drifted away from.
//
// What it drives is a gateway that serves two nodes, because one is not enough to
// say what the protocol is: a request names the node it is for, and a device is
// admitted to the ones it holds and to nothing else.
package entrancetest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"software.sslmate.com/src/go-pkcs12"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/entrance"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

// The password a device encrypts its credential with. It is a test value, never
// a secret.
const credentialPassword = "credential-password-123"

// AppID is the application both machines behind a shape run: what opening one of
// them is about, and what an application's own origin serves.
const AppID = "editor"

// pagePath is one path of that application. It is the application's own traffic
// rather than its control surface, and it belongs to the application's own origin:
// what a client is redirected to when it opens the application.
const pagePath = "/editor/"

// NodeIDs and NodeNames are the two machines a shape's harness stands up behind
// its entrance: an id is what a request names a node by, and a name is what an
// operator and a client show. Both shapes are driven against the same pair.
var (
	NodeIDs   = [2]string{strings.Repeat("11", 32), strings.Repeat("22", 32)}
	NodeNames = [2]string{"Desk", "Laptop"}
)

// Harness is what one shape tells the suite so the suite can drive it.
type Harness interface {
	// Gateway is the shape under test, opened on a state of its own and serving
	// on addresses of its own.
	Gateway() entrance.Gateway
	// Dial sends one request the way this shape's clients send it: over the mTLS
	// this entrance terminates itself, or through the entrance that authenticates
	// them for it. A nil credential is a client that has no credential yet.
	Dial(credential *tls.Certificate, method, path string, header map[string]string, body []byte) (int, string, error)
	// Open asks the gateway to open one application of one node, the way a client
	// does, and answers with what it was told — the status, and the location of the
	// redirect: an origin of that application's own, which is what the client loads
	// next and where the application's storage is.
	Open(credential *tls.Certificate, node gatewaycore.Node, appID string) (int, string, error)
	// DialApplication sends one request the way this shape's clients reach an
	// application at its own origin, as Open named it: an address that is not the
	// one the protocol's other requests are asked on, whether that is because it is
	// another host or another port.
	DialApplication(credential *tls.Certificate, node gatewaycore.Node, appID, method, path string, header map[string]string, body []byte) (int, string, error)
	// ApprovesInline reports whether redeeming an invitation is the whole
	// admission, because the operator who handed it over already approved the
	// device — a LAN entrance — rather than the operator confirming the device
	// after it pairs, which is what a public entrance needs.
	ApprovesInline() bool
	// Approve does what this shape's operator does to admit a paired device, for
	// a shape that does not admit it inline.
	Approve(fingerprint string) error
	// NodeSaw is every request one node behind this gateway was asked for, in
	// order: a request the entrance refuses must never appear here.
	NodeSaw(nodeID string) []string
}

// Run drives one shape through the whole admission protocol.
func Run(t *testing.T, harness Harness) {
	t.Helper()
	gateway := harness.Gateway()
	trust := gateway.Trust()
	nodes := gateway.State().Nodes
	if len(nodes) < 2 {
		t.Fatalf("this suite drives a gateway that serves two nodes, and this one serves %d", len(nodes))
	}
	first, second := nodes[0], nodes[1]
	forNode := func(node gatewaycore.Node) map[string]string {
		return map[string]string{proxysecurity.NodeHeader: node.ID}
	}

	t.Run("a device is admitted only once its admission allows it", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))

		if status, _, err := harness.Dial(nil, http.MethodPost, "/__remote_everything_activate", forNode(first), nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("activation without a credential was answered with %d, %v", status, err)
		}
		if !harness.ApprovesInline() {
			// A device that paired but has not asked yet is not admitted either:
			// its operator has nothing to confirm until it does.
			if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(first), nil); err != nil || status != http.StatusUnauthorized {
				t.Fatalf("a device was admitted before it was approved: %d %s %v", status, body, err)
			}
		}
		admit(t, harness, fingerprint, credential, first)

		// The node is reached through the admitted device, and everything that
		// reaches it is behind the same admission: what an entrance answers is the
		// node's, and the tenant of that answer is this device.
		if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(first), nil); err != nil || status != http.StatusOK || !connected(t, body) {
			t.Fatalf("the admitted device did not reach the node: %d %s %v", status, body, err)
		}
	})

	t.Run("an application is served at an origin of its own", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))
		admit(t, harness, fingerprint, credential, first)

		// Opening an application answers with an address of that application's own —
		// absolute, so a client resolves nothing — and the same one every time:
		// coming back to an application comes back to where it kept its storage.
		status, location, err := harness.Open(credential, first, AppID)
		if err != nil {
			t.Fatal(err)
		}
		if status != http.StatusFound || !isOrigin(location) {
			t.Fatalf("opening %s answered %d %q", AppID, status, location)
		}
		if _, again, err := harness.Open(credential, first, AppID); err != nil || again != location {
			t.Fatalf("opening %s twice moved it: %q then %q (%v)", AppID, location, again, err)
		}
		// The application answers there, to the device that holds the node it
		// belongs to.
		if status, body, err := harness.DialApplication(credential, first, AppID, http.MethodGet, pagePath, nil, nil); err != nil || status != http.StatusOK {
			t.Fatalf("the application did not answer at its own origin: %d %s %v", status, body, err)
		}
		// A client with no credential reaches nothing there, and neither does a
		// device that does not hold this node — without the node hearing about
		// either: what is refused before it is routed never reaches it.
		seen := len(harness.NodeSaw(first.ID))
		if status, body, err := harness.DialApplication(nil, first, AppID, http.MethodGet, pagePath, nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a client with no credential reached an application: %d %s %v", status, body, err)
		}
		if status, body, err := harness.DialApplication(credential, second, AppID, http.MethodGet, pagePath, nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a device reached an application of a node it does not hold: %d %s %v", status, body, err)
		}
		if len(harness.NodeSaw(first.ID)) != seen {
			t.Fatal("an application request that was refused was forwarded to the node")
		}
		// The protocol's paths and the control plane are not part of an
		// application: an origin that serves one serves it and nothing else.
		for _, refused := range []struct {
			path string
			code int
		}{
			{"/__remote_everything/nodes", http.StatusNotFound},
			{"/__remote_everything/apps", http.StatusNotFound},
			{"/__remote_everything/open/" + AppID, http.StatusNotFound},
			{proxysecurity.ControlPath, http.StatusForbidden},
		} {
			if status, body, err := harness.DialApplication(credential, first, AppID, http.MethodGet, refused.path, nil, nil); err != nil || status != refused.code {
				t.Fatalf("%s on an application origin answered %d %s %v", refused.path, status, body, err)
			}
		}
		// And the control origin is not where an application is served: it carries
		// the protocol, and a client loads the application from the origin it was
		// redirected to.
		if status, body, err := harness.Dial(credential, http.MethodGet, pagePath, forNode(first), nil); err != nil || status != http.StatusNotFound || !strings.Contains(body, `"not_found"`) {
			t.Fatalf("the control origin answered an application path with %d %s %v", status, body, err)
		}
	})

	t.Run("a request the entrance refuses never reaches the node", func(t *testing.T) {
		seen := len(harness.NodeSaw(first.ID))
		// Neither the control surface nor an application: an entrance that let
		// anything reach a node before admitting a device would be answering for it.
		for _, path := range []string{"/__remote_everything/apps", pagePath} {
			if status, _, err := harness.Dial(nil, http.MethodGet, path, forNode(first), nil); err != nil || status != http.StatusUnauthorized {
				t.Fatalf("an unpaired client reached %s with %d, %v", path, status, err)
			}
		}
		if status, _, err := harness.DialApplication(nil, first, AppID, http.MethodGet, pagePath, nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("an unpaired client reached an application with %d, %v", status, err)
		}
		if len(harness.NodeSaw(first.ID)) != seen {
			t.Fatal("a refused request was forwarded to the node")
		}
	})

	t.Run("a device cannot name itself", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))
		admit(t, harness, fingerprint, credential, first)
		claim := forNode(first)
		claim[proxysecurity.ClientFingerprintHeader] = fingerprint
		if status, _, err := harness.Dial(nil, http.MethodGet, "/__remote_everything/apps", claim, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a fingerprint a client claimed for itself was believed: %d %v", status, err)
		}
	})

	t.Run("a certificate this entrance never issued is not a credential", func(t *testing.T) {
		stranger := strangerCredential(t)
		if status, _, err := harness.Dial(stranger, http.MethodGet, "/__remote_everything/apps", forNode(first), nil); err == nil && status != http.StatusUnauthorized {
			t.Fatalf("a certificate this entrance never issued was admitted: %d", status)
		}
	})

	t.Run("an invitation admits one device", func(t *testing.T) {
		invitation := issueInvitation(t, harness, first)
		pair(t, harness, invitation)
		body, _ := json.Marshal(map[string]string{"device_name": "Other Phone", "credential_password": credentialPassword})
		status, _, err := harness.Dial(nil, http.MethodPost, "/__remote_everything_pair", map[string]string{"Authorization": "Invitation " + invitation}, body)
		if err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a spent invitation was answered with %d, %v", status, err)
		}
	})

	t.Run("an invitation opens one node and no other", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, second))
		admit(t, harness, fingerprint, credential, second)
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(second), nil); err != nil || status != http.StatusOK {
			t.Fatalf("the node the invitation opened was not reachable: %d %v", status, err)
		}
		seen := len(harness.NodeSaw(first.ID))
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(first), nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a device reached a node its invitation did not open: %d %v", status, err)
		}
		if status, _, err := harness.DialApplication(credential, first, AppID, http.MethodGet, pagePath, nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("an application of a node the device does not hold was served: %d %v", status, err)
		}
		if len(harness.NodeSaw(first.ID)) != seen {
			t.Fatal("a refused request was forwarded to the node it was refused for")
		}
	})

	t.Run("a request says which node it is for", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))
		admit(t, harness, fingerprint, credential, first)
		seen := map[string]int{first.ID: len(harness.NodeSaw(first.ID)), second.ID: len(harness.NodeSaw(second.ID))}
		// Neither a request that names no node nor one that names a node this
		// gateway does not serve is answered by guessing which node was meant.
		for _, header := range []map[string]string{
			nil,
			{proxysecurity.NodeHeader: strings.Repeat("ee", 32)},
			{proxysecurity.NodeHeader: "Desk"},
		} {
			if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", header, nil); err != nil || status != http.StatusUnauthorized {
				t.Fatalf("a request naming no node of this gateway was answered with %d, %v", status, err)
			}
		}
		for _, node := range nodes {
			if len(harness.NodeSaw(node.ID)) != seen[node.ID] {
				t.Fatalf("node %s answered a request that named no node of it", node.Name)
			}
		}
	})

	t.Run("a node granted to a device is reachable without pairing again", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))
		admit(t, harness, fingerprint, credential, first)
		if listed := nodeList(t, harness, credential, first); len(listed) != 1 || listed[0] != first.Name {
			t.Fatalf("a device holds %v", listed)
		}
		if _, err := runCLI(trust, "grant", "--node", second.ID, fingerprint); err != nil {
			t.Fatal(err)
		}
		if listed := nodeList(t, harness, credential, first); len(listed) != 2 || listed[0] != first.Name || listed[1] != second.Name {
			t.Fatalf("a granted node is not what the device may reach: %v", listed)
		}
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(second), nil); err != nil || status != http.StatusOK {
			t.Fatalf("a granted node was not reachable: %d %v", status, err)
		}
		// And withdrawing it again takes that one away and leaves the other.
		if _, err := runCLI(trust, "revoke", "--node", second.ID, fingerprint); err != nil {
			t.Fatal(err)
		}
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(second), nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a withdrawn node was reachable: %d %v", status, err)
		}
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(first), nil); err != nil || status != http.StatusOK {
			t.Fatalf("withdrawing one node took another away: %d %v", status, err)
		}
	})

	t.Run("revoking a device stops it", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))
		admit(t, harness, fingerprint, credential, first)
		if _, err := runCLI(trust, "revoke", fingerprint); err != nil {
			t.Fatal(err)
		}
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", forNode(first), nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a revoked device was still admitted: %d %v", status, err)
		}
	})

	t.Run("the origin, the listeners and the nodes are what the state recorded", func(t *testing.T) {
		state := gateway.State()
		if state.Origin == "" || len(state.Listeners) == 0 {
			t.Fatalf("the gateway did not record what clients dial it by: %+v", state)
		}
		for _, listener := range state.Listeners {
			if _, err := state.Address(listener.Name); err != nil {
				t.Fatalf("listener %s is not addressable: %v", listener.Name, err)
			}
		}
		for _, node := range state.Nodes {
			if node.ID == "" || node.Name == "" || node.Address == "" {
				t.Fatalf("the gateway did not record a node it serves: %+v", node)
			}
		}
	})
}

// isOrigin reports whether a location an application was opened at is an origin
// of its own: absolute, over HTTPS, and at the root of that origin, which is what
// a client loads — it resolves the location against nothing, and the path it
// appends to it is the application's.
func isOrigin(location string) bool {
	parsed, err := url.Parse(location)
	return err == nil && parsed.Scheme == "https" && parsed.Host != "" &&
		(parsed.Path == "" || parsed.Path == "/") && parsed.RawQuery == "" && parsed.Fragment == "" && parsed.User == nil
}

// nodeList asks the gateway which nodes this device may reach, which is how a
// device finds out about a node it was granted.
func nodeList(t *testing.T, harness Harness, credential *tls.Certificate, node gatewaycore.Node) []string {
	t.Helper()
	status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/nodes", map[string]string{proxysecurity.NodeHeader: node.ID}, nil)
	if err != nil || status != http.StatusOK {
		t.Fatalf("listing what a device may reach answered %d %s %v", status, body, err)
	}
	var payload struct {
		OK    bool `json:"ok"`
		Nodes []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"nodes"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		t.Fatalf("node list %q: %v", body, err)
	}
	if !payload.OK {
		t.Fatalf("node list is not an answer: %s", body)
	}
	names := make([]string, 0, len(payload.Nodes))
	for _, node := range payload.Nodes {
		names = append(names, node.Name)
	}
	return names
}

// admit brings a paired device to the state its entrance admits it in. For a
// shape whose invitations are the approval that is activation itself; for one
// whose operator confirms devices, activation is what raises the request the
// operator then answers.
func admit(t *testing.T, harness Harness, fingerprint string, credential *tls.Certificate, node gatewaycore.Node) {
	t.Helper()
	header := map[string]string{proxysecurity.NodeHeader: node.ID}
	status, body, err := harness.Dial(credential, http.MethodPost, "/__remote_everything_activate", header, nil)
	if err != nil {
		t.Fatal(err)
	}
	if harness.ApprovesInline() {
		if status != http.StatusOK || !connected(t, body) {
			t.Fatalf("activation was not admitted by the invitation: %d %s", status, body)
		}
		return
	}
	if status != http.StatusAccepted {
		t.Fatalf("activation was not left waiting for the operator: %d %s", status, body)
	}
	if err := harness.Approve(fingerprint); err != nil {
		t.Fatal(err)
	}
	if status, body, err = harness.Dial(credential, http.MethodPost, "/__remote_everything_activate", header, nil); err != nil || status != http.StatusOK {
		t.Fatalf("approval did not admit the device: %d %s %v", status, body, err)
	}
}

// issueInvitation hands out an invitation for one node the way an operator does,
// and checks that what it carries is enough for a client to dial, name and trust
// this entrance.
func issueInvitation(t *testing.T, harness Harness, node gatewaycore.Node) string {
	t.Helper()
	output, err := runCLI(harness.Gateway().Trust(), "invite", "--name", "Test Phone", "--node", node.ID, "--ttl", "10m")
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Invitation string `json:"invitation"`
		SetupURI   string `json:"setup_uri"`
	}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		t.Fatalf("invitation output %q: %v", output, err)
	}
	if len(result.Invitation) != 43 || result.SetupURI == "" {
		t.Fatalf("the invitation is not deliverable: %q", output)
	}
	uri, err := url.Parse(result.SetupURI)
	if err != nil {
		t.Fatalf("setup URI %q: %v", result.SetupURI, err)
	}
	if uri.Query().Get("node") != node.ID || uri.Query().Get("node_name") != node.Name {
		t.Fatalf("the invitation does not say which node it opens: %s", result.SetupURI)
	}
	return result.Invitation
}

func runCLI(trust *devicecore.Trust, args ...string) (string, error) {
	var buffer bytes.Buffer
	if err := trust.RunCLI(args, &buffer); err != nil {
		return "", err
	}
	return buffer.String(), nil
}

// pair redeems an invitation the way a device does: with no credential at all,
// asking for one of its own. It names no node, because the invitation is what
// decides which one the device is being admitted to.
func pair(t *testing.T, harness Harness, invitation string) (string, *tls.Certificate) {
	t.Helper()
	body, err := json.Marshal(map[string]string{"device_name": "Test Phone", "credential_password": credentialPassword})
	if err != nil {
		t.Fatal(err)
	}
	status, contents, err := harness.Dial(nil, http.MethodPost, "/__remote_everything_pair", map[string]string{"Authorization": "Invitation " + invitation}, body)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK {
		t.Fatalf("pairing was refused: %d %s", status, contents)
	}
	var result struct {
		CertificateFingerprint string `json:"certificate_fingerprint"`
		CredentialPKCS12       string `json:"credential_pkcs12"`
	}
	if err := json.Unmarshal([]byte(contents), &result); err != nil {
		t.Fatal(err)
	}
	encoded, err := base64.StdEncoding.DecodeString(result.CredentialPKCS12)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, certificate, chain, err := pkcs12.DecodeChain(encoded, credentialPassword)
	if err != nil {
		t.Fatal(err)
	}
	if devicecore.CertificateFingerprint(certificate) != result.CertificateFingerprint {
		t.Fatal("the credential is not the one it was issued under")
	}
	// Every case that needs a credential comes through here, so this is where the
	// credential itself is checked: it is the one it was issued as, and it chains
	// to this entrance's own authority rather than to anyone else's.
	if len(chain) != 1 || !chain[0].Equal(harness.Gateway().Trust().Issuer()) {
		t.Fatal("the credential does not chain to this entrance's device authority")
	}
	key, ok := privateKey.(*ecdsa.PrivateKey)
	if !ok {
		t.Fatal("the device credential is not an ECDSA key")
	}
	return result.CertificateFingerprint, &tls.Certificate{Certificate: [][]byte{certificate.Raw}, PrivateKey: key}
}

// strangerCredential is what an attacker on the same network can produce on their
// own: a certificate this entrance never issued.
func strangerCredential(t *testing.T) *tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test Phone"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return &tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func connected(t *testing.T, body string) bool {
	t.Helper()
	var payload struct {
		OK                bool `json:"ok"`
		ComputerConnected bool `json:"computer_connected"`
	}
	if err := json.Unmarshal([]byte(body), &payload); err != nil {
		t.Fatalf("response %q: %v", body, err)
	}
	return payload.OK && payload.ComputerConnected
}
