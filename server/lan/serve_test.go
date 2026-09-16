package main

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
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"software.sslmate.com/src/go-pkcs12"

	"github.com/hxaxd/remote-everything/internal/devicecore"
)

const testCredentialPassword = "credential-password-123"

// lanEntrance is an entrance serving on a real port with the TLS material it
// generated, which is what its clients see.
type lanEntrance struct {
	service *lanService
	origin  string
	pinned  *x509.Certificate
}

func nodeStub(t *testing.T) *httptest.Server {
	t.Helper()
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		if request.URL.Path != "/__local_remote_control" {
			_, _ = io.WriteString(writer, `{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}`)
			return
		}
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"editor","name":"Editor","description":"","icon":"E","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
	}))
	t.Cleanup(node.Close)
	return node
}

func startLANEntrance(t *testing.T) *lanEntrance {
	t.Helper()
	node := nodeStub(t)
	root := t.TempDir()
	if _, err := initializeLAN(root, strings.TrimPrefix(node.URL, "http://"), "127.0.0.1", 30, t.TempDir()); err != nil {
		t.Fatal(err)
	}
	service, err := openLANService(root)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server, err := service.gatewayServer(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = server.ServeTLS(listener, "", "") }()
	t.Cleanup(func() { _ = server.Close() })
	pinned, err := loadLANCertificate(root, service.state.LAN.Host, service.state)
	if err != nil {
		t.Fatal(err)
	}
	return &lanEntrance{service: service, origin: "https://" + listener.Addr().String(), pinned: pinned}
}

// clientFor builds a client that trusts exactly the entrance certificate it was
// given, the way a paired client does, and presents an identity when it has one.
type listedDeviceRecord struct {
	CertificateFingerprint string `json:"certificate_fingerprint"`
	Status                 string `json:"status"`
	ApprovedAt             string `json:"approved_at"`
	ActivatedAt            string `json:"activated_at"`
}

func listedDevice(t *testing.T, entrance *lanEntrance, fingerprint string) listedDeviceRecord {
	t.Helper()
	var output bytes.Buffer
	if err := entrance.service.trust.RunCLI([]string{"list"}, &output); err != nil {
		t.Fatal(err)
	}
	var records []listedDeviceRecord
	if err := json.Unmarshal(output.Bytes(), &records); err != nil {
		t.Fatalf("device list %q: %v", output.String(), err)
	}
	for _, record := range records {
		if record.CertificateFingerprint == fingerprint {
			return record
		}
	}
	t.Fatalf("device %s is not on the list: %s", fingerprint, output.String())
	return listedDeviceRecord{}
}

func (entrance *lanEntrance) clientFor(certificatePair *tls.Certificate) *http.Client {
	configuration := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: x509.NewCertPool()}
	configuration.RootCAs.AddCert(entrance.pinned)
	if certificatePair != nil {
		configuration.Certificates = []tls.Certificate{*certificatePair}
	}
	return &http.Client{
		Timeout:   5 * time.Second,
		Transport: &http.Transport{TLSClientConfig: configuration},
	}
}

func (entrance *lanEntrance) do(t *testing.T, certificatePair *tls.Certificate, method, target string, body io.Reader, header map[string]string) (int, string, error) {
	t.Helper()
	request, err := http.NewRequest(method, entrance.origin+target, body)
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range header {
		request.Header.Set(name, value)
	}
	response, err := entrance.clientFor(certificatePair).Do(request)
	if err != nil {
		return 0, "", err
	}
	defer response.Body.Close()
	contents, _ := io.ReadAll(response.Body)
	return response.StatusCode, string(contents), nil
}

// invitation issues one the way an operator does, and checks that the URI it
// comes in describes the entrance a client has to dial.
func invitation(t *testing.T, entrance *lanEntrance) string {
	t.Helper()
	var output bytes.Buffer
	if err := entrance.service.trust.RunCLI([]string{"invite", "--name", "Test Phone", "--ttl", "10m"}, &output); err != nil {
		t.Fatal(err)
	}
	var result struct {
		Invitation string `json:"invitation"`
		SetupURI   string `json:"setup_uri"`
	}
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatalf("invite output %q: %v", output.String(), err)
	}
	parsed, err := url.Parse(result.SetupURI)
	if err != nil {
		t.Fatal(err)
	}
	// The invitation names the origin the entrance recorded for itself; the test
	// serves that entrance on a port of its own, so it dials one address and the
	// invitation carries the other.
	query := parsed.Query()
	if query.Get("mode") != "lan" || query.Get("origin") != entrance.service.state.LAN.GatewayOrigin || query.Get("invitation") != result.Invitation {
		t.Fatalf("LAN setup URI does not describe the entrance: %s", result.SetupURI)
	}
	if query.Get("fingerprint") != devicecore.CertificateFingerprint(entrance.pinned) || query.Get("public_key_pin") != devicecore.PublicKeyPin(entrance.pinned) {
		t.Fatalf("LAN setup URI does not pin the certificate the entrance serves: %s", result.SetupURI)
	}
	return result.Invitation
}

// pair redeems an invitation the way a phone does: over TLS, with no certificate
// at all, asking for the credential it uses from then on.
func pair(t *testing.T, entrance *lanEntrance, token string) (string, *tls.Certificate) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"device_name": "Test Phone", "credential_password": testCredentialPassword})
	status, contents, err := entrance.do(t, nil, http.MethodPost, "/__remote_everything_pair", bytes.NewReader(body), map[string]string{"Authorization": "Invitation " + token})
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK {
		t.Fatalf("pairing was not admitted: %d %s", status, contents)
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
	privateKey, certificate, chain, err := pkcs12.DecodeChain(encoded, testCredentialPassword)
	if err != nil {
		t.Fatal(err)
	}
	// The credential has to be the one the record was written under, chaining to
	// this entrance's own authority.
	if devicecore.CertificateFingerprint(certificate) != result.CertificateFingerprint {
		t.Fatal("the issued credential is not the one it was issued under")
	}
	if len(chain) != 1 || !chain[0].Equal(entrance.service.trust.Issuer()) {
		t.Fatal("the issued credential does not chain to this entrance's device authority")
	}
	key, ok := privateKey.(*ecdsa.PrivateKey)
	if !ok {
		t.Fatal("the device credential is not an ECDSA key")
	}
	return result.CertificateFingerprint, &tls.Certificate{Certificate: [][]byte{certificate.Raw}, PrivateKey: key}
}

// strangerCredential is what an attacker on the same network can produce on
// their own: a certificate this entrance never issued.
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

// A LAN entrance admits a device by the invitation it was handed and then by the
// certificate it was issued. No entrance-wide secret appears in that story: one
// token admitted whoever learned it as every device at once.
func TestLANAdmitsThePairedDeviceAndNothingElse(t *testing.T) {
	entrance := startLANEntrance(t)
	token := invitation(t, entrance)

	if status, _, err := entrance.do(t, nil, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("an unpaired client reached the node: %d %v", status, err)
	}
	// A certificate from another authority does not even complete the handshake:
	// the entrance verifies them against the authority it issues devices from.
	if status, _, err := entrance.do(t, strangerCredential(t), http.MethodGet, "/__remote_everything/apps", nil, nil); err == nil && status != http.StatusUnauthorized {
		t.Fatalf("a certificate this entrance never issued was admitted: %d", status)
	}

	fingerprint, credential := pair(t, entrance, token)
	if status, body, err := entrance.do(t, credential, http.MethodPost, "/__remote_everything_activate", nil, nil); err != nil || status != http.StatusOK || !strings.Contains(body, `"id":"editor"`) {
		t.Fatalf("the paired device was not activated: %d %s %v", status, body, err)
	}
	if status, body, err := entrance.do(t, credential, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusOK || !strings.Contains(body, `"id":"editor"`) {
		t.Fatalf("the paired device could not reach the node: %d %s %v", status, body, err)
	}
	// The invitation was the approval: this entrance has no operator watching for
	// a device to confirm, so the device is on the list the moment it activates.
	if record := listedDevice(t, entrance, fingerprint); record.Status != "approved" || record.ActivatedAt == "" || record.ApprovedAt == "" {
		t.Fatalf("the device list does not show what happened: %+v", record)
	}
}

// Pairing is the one surface an entrance answers without a credential, so it has
// to be the only one, and application traffic has to stay out of it: a page load
// in a WebView cannot carry a certificate the way a control call can, and the
// node authorizes it by the routing cookie it sets when an application opens.
func TestLANAnswersPairingWithoutACredentialAndLeavesApplicationTrafficToTheNode(t *testing.T) {
	entrance := startLANEntrance(t)
	if status, _, err := entrance.do(t, nil, http.MethodGet, "/__remote_everything/apps", nil, nil); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("an unauthenticated client reached a control surface: %d %v", status, err)
	}
	if status, _, err := entrance.do(t, nil, http.MethodGet, "/editor/", nil, nil); err != nil || status != http.StatusOK {
		t.Fatalf("application traffic was refused at the entrance: %d %v", status, err)
	}
	if status, _, err := entrance.do(t, nil, http.MethodGet, "/healthz", nil, nil); err != nil || status != http.StatusOK {
		t.Fatalf("the entrance is not answering health checks: %d %v", status, err)
	}
}

// A client cannot name the device it wants to be: the fingerprint it sends is
// dropped, and only the certificate it presented can speak for it. The device
// here is approved, so believing the claim would admit a request that carried no
// credential at all.
func TestLANIgnoresAFingerprintTheClientClaims(t *testing.T) {
	entrance := startLANEntrance(t)
	fingerprint, credential := pair(t, entrance, invitation(t, entrance))
	if status, body, err := entrance.do(t, credential, http.MethodPost, "/__remote_everything_activate", nil, nil); err != nil || status != http.StatusOK {
		t.Fatalf("the device was not activated: %d %s %v", status, body, err)
	}
	claim := map[string]string{"X-Remote-Everything-Client-Fingerprint": fingerprint}
	if status, _, err := entrance.do(t, nil, http.MethodGet, "/__remote_everything/apps", nil, claim); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("a claimed fingerprint was believed: %d %v", status, err)
	}
	// Beside a real credential the same claim neither helps nor hurts: what is
	// read is the certificate, and it is the paired device that presented it.
	if status, _, err := entrance.do(t, credential, http.MethodGet, "/__remote_everything/apps", nil, claim); err != nil || status != http.StatusOK {
		t.Fatalf("a claim beside a real credential was misread: %d %v", status, err)
	}
}
