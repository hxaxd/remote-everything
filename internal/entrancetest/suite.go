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
package entrancetest

import (
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
	"testing"
	"time"

	"software.sslmate.com/src/go-pkcs12"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/entrance"
)

// The password a device encrypts its credential with. It is a test value, never
// a secret.
const credentialPassword = "credential-password-123"

// Harness is what one shape tells the suite so the suite can drive it.
type Harness interface {
	// Gateway is the shape under test, opened on a state of its own and serving
	// on addresses of its own.
	Gateway() entrance.Gateway
	// Dial sends one request the way this shape's clients send it: over the mTLS
	// this entrance terminates itself, or through the entrance that authenticates
	// them for it. A nil credential is a client that has no credential yet.
	Dial(credential *tls.Certificate, method, path string, header map[string]string, body []byte) (int, string, error)
	// ApprovesInline reports whether redeeming an invitation is the whole
	// admission, because the operator who handed it over already approved the
	// device — a LAN entrance — rather than the operator confirming the device
	// after it pairs, which is what a public entrance needs.
	ApprovesInline() bool
	// Approve does what this shape's operator does to admit a paired device, for
	// a shape that does not admit it inline.
	Approve(fingerprint string) error
	// NodeSaw is every request the node behind this gateway was asked for, in
	// order: a request the entrance refuses must never appear here.
	NodeSaw() []string
}

// Run drives one shape through the whole admission protocol.
func Run(t *testing.T, harness Harness) {
	t.Helper()
	gateway := harness.Gateway()
	trust := gateway.Trust()

	t.Run("an invitation pairs a device and the credential chains to the entrance", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness))
		if fingerprint == "" || credential == nil {
			t.Fatal("pairing issued nothing")
		}
	})

	t.Run("a device is admitted only once its admission allows it", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness))

		if status, _, err := harness.Dial(nil, http.MethodPost, "/__remote_everything_activate", nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("activation without a credential was answered with %d, %v", status, err)
		}
		if !harness.ApprovesInline() {
			// A device that paired but has not asked yet is not admitted either:
			// its operator has nothing to confirm until it does.
			if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusUnauthorized {
				t.Fatalf("a device was admitted before it was approved: %d %s %v", status, body, err)
			}
		}
		admit(t, harness, fingerprint, credential)

		// The node is reached through the admitted device.
		if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusOK || !connected(t, body) {
			t.Fatalf("the admitted device did not reach the node: %d %s %v", status, body, err)
		}
	})

	t.Run("a request the entrance refuses never reaches the node", func(t *testing.T) {
		seen := len(harness.NodeSaw())
		if status, _, err := harness.Dial(nil, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("an unpaired client was answered with %d, %v", status, err)
		}
		if len(harness.NodeSaw()) != seen {
			t.Fatal("a refused request was forwarded to the node")
		}
	})

	t.Run("a device cannot name itself", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness))
		admit(t, harness, fingerprint, credential)
		claim := map[string]string{"X-Remote-Everything-Client-Fingerprint": fingerprint}
		if status, _, err := harness.Dial(nil, http.MethodGet, "/__remote_everything/apps", claim, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a fingerprint a client claimed for itself was believed: %d %v", status, err)
		}
	})

	t.Run("a certificate this entrance never issued is not a credential", func(t *testing.T) {
		stranger := strangerCredential(t)
		if status, _, err := harness.Dial(stranger, http.MethodGet, "/__remote_everything/apps", nil, nil); err == nil && status != http.StatusUnauthorized {
			t.Fatalf("a certificate this entrance never issued was admitted: %d", status)
		}
	})

	t.Run("an invitation admits one device", func(t *testing.T) {
		invitation := issueInvitation(t, harness)
		pair(t, harness, invitation)
		body, _ := json.Marshal(map[string]string{"device_name": "Other Phone", "credential_password": credentialPassword})
		status, _, err := harness.Dial(nil, http.MethodPost, "/__remote_everything_pair", map[string]string{"Authorization": "Invitation " + invitation}, body)
		if err != nil || status == http.StatusOK {
			t.Fatalf("an invitation that was spent paired another device: %d %v", status, err)
		}
	})

	t.Run("revoking a device stops it", func(t *testing.T) {
		fingerprint, credential := pair(t, harness, issueInvitation(t, harness))
		admit(t, harness, fingerprint, credential)
		if _, err := runCLI(trust, "revoke", fingerprint); err != nil {
			t.Fatal(err)
		}
		if status, _, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusUnauthorized {
			t.Fatalf("a revoked device was still admitted: %d %v", status, err)
		}
	})

	t.Run("the origin and the listeners are what the state recorded", func(t *testing.T) {
		state := gateway.State()
		if state.Origin == "" || len(state.Listeners) == 0 {
			t.Fatalf("the gateway did not record what clients dial it by: %+v", state)
		}
		for _, listener := range state.Listeners {
			if _, err := state.Address(listener.Name); err != nil {
				t.Fatalf("listener %s is not addressable: %v", listener.Name, err)
			}
		}
	})
}

// admit brings a paired device to the state its entrance admits it in. For a
// shape whose invitations are the approval that is activation itself; for one
// whose operator confirms devices, activation is what raises the request the
// operator then answers.
func admit(t *testing.T, harness Harness, fingerprint string, credential *tls.Certificate) {
	t.Helper()
	status, body, err := harness.Dial(credential, http.MethodPost, "/__remote_everything_activate", nil, nil)
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
	if status, body, err = harness.Dial(credential, http.MethodPost, "/__remote_everything_activate", nil, nil); err != nil || status != http.StatusOK {
		t.Fatalf("approval did not admit the device: %d %s %v", status, body, err)
	}
}

// issueInvitation hands out an invitation the way an operator does, and checks
// that what it carries is enough for a client to dial and trust this entrance.
func issueInvitation(t *testing.T, harness Harness) string {
	t.Helper()
	output, err := runCLI(harness.Gateway().Trust(), "invite", "--name", "Test Phone", "--ttl", "10m")
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
	return result.Invitation
}

func runCLI(trust *devicecore.Trust, args ...string) (string, error) {
	var buffer writeBuffer
	if err := trust.RunCLI(args, &buffer); err != nil {
		return "", err
	}
	return buffer.value, nil
}

type writeBuffer struct{ value string }

func (buffer *writeBuffer) Write(contents []byte) (int, error) {
	buffer.value += string(contents)
	return len(contents), nil
}

// pair redeems an invitation the way a device does: with no credential at all,
// asking for one of its own.
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
