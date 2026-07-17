package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pkcs12 "software.sslmate.com/src/go-pkcs12"
)

type cliFixture struct {
	issuerKey  *ecdsa.PrivateKey
	issuerCert *x509.Certificate
	execCalls  [][]string
	audit      *bytes.Buffer
}

func setupCLI(t *testing.T) *cliFixture {
	t.Helper()
	directory := t.TempDir()
	enrollStateDir = filepath.Join(directory, "requests")
	approvedDir = filepath.Join(directory, "approved-clients")
	bootstrapCAFile = filepath.Join(directory, "bootstrap-ca.crt.pem")
	trustBundleFile = filepath.Join(directory, "client-trust.pem")
	issuerKeyFile = filepath.Join(directory, "device-issuer.key.pem")
	issuerCertFile = filepath.Join(directory, "device-issuer.crt.pem")
	caddyConfigFile = filepath.Join(directory, "Caddyfile")
	bootstrapFingerprintFile = filepath.Join(directory, "bootstrap-fingerprint")
	logOut = io.Discard
	audit := &bytes.Buffer{}
	auditOut = audit
	fixture := &cliFixture{audit: audit}
	euidFunc = func() int { return 0 }
	chownFunc = func(path, name string) error { return nil }
	execFunc = func(name string, args ...string) error {
		fixture.execCalls = append(fixture.execCalls, append([]string{name}, args...))
		return nil
	}
	t.Cleanup(func() {
		enrollStateDir = "/var/lib/kimi-enrollment/requests"
		approvedDir = "/etc/kimi-gateway/approved-clients"
		bootstrapCAFile = "/etc/kimi-gateway/bootstrap-ca.crt.pem"
		trustBundleFile = "/etc/kimi-gateway/client-trust.pem"
		issuerKeyFile = "/etc/kimi-gateway/device-issuer.key.pem"
		issuerCertFile = "/etc/kimi-gateway/device-issuer.crt.pem"
		caddyConfigFile = "/etc/caddy/Caddyfile"
		bootstrapFingerprintFile = "/etc/kimi-gateway/bootstrap-fingerprint"
		euidFunc = platformEUID
		chownFunc = platformChownUser
		execFunc = runChecked
		logOut = os.Stdout
		auditOut = os.Stderr
	})

	if err := os.MkdirAll(enrollStateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(approvedDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bootstrapFingerprintFile, []byte("fp\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(caddyConfigFile, []byte("# test\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	issuerKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	issuerTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Agent Remote Device Issuer"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(3650 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		MaxPathLen:            0,
		MaxPathLenZero:        true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	issuerDER, err := x509.CreateCertificate(rand.Reader, issuerTemplate, issuerTemplate, &issuerKey.PublicKey, issuerKey)
	if err != nil {
		t.Fatal(err)
	}
	fixture.issuerKey = issuerKey
	if fixture.issuerCert, err = x509.ParseCertificate(issuerDER); err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(issuerKey)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(issuerKeyFile, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(issuerCertFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: issuerDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bootstrapCAFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: issuerDER}), 0o644); err != nil {
		t.Fatal(err)
	}
	return fixture
}

func createPending(t *testing.T, deviceName, password string) publicStateJSON {
	t.Helper()
	proof := makeProof(t, deviceName)
	created, err := createEnrollRequest(deviceName, proof.PEM, proof.Nonce, proof.Signature, "pkcs12", password)
	if err != nil {
		t.Fatal(err)
	}
	return created
}

func TestApproveFlow(t *testing.T) {
	fixture := setupCLI(t)
	created := createPending(t, "my phone", "Abcdef0123456789_-abcd")
	code := created.RegistrationCode
	requestID := created.RequestID

	stdout := &bytes.Buffer{}
	if err := runEnrollCLI([]string{"approve", code}, stdout); err != nil {
		t.Fatal(err)
	}
	var printed map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &printed); err != nil {
		t.Fatalf("approve output not json: %s", stdout.String())
	}
	if printed["status"] != "approved" {
		t.Fatalf("not approved: %s", stdout.String())
	}
	if _, leaked := printed["credential_password"]; leaked {
		t.Fatal("credential_password in approve output")
	}
	encoded, ok := printed["credential_pkcs12"].(string)
	if !ok || encoded == "" {
		t.Fatalf("credential_pkcs12 missing: %s", stdout.String())
	}
	if !strings.Contains(fixture.audit.String(), `"enrollment approved"`) || !strings.Contains(fixture.audit.String(), code) {
		t.Fatalf("audit line missing: %s", fixture.audit.String())
	}
	if strings.Contains(fixture.audit.String(), encoded) || strings.Contains(fixture.audit.String(), "Abcdef0123456789_-abcd") {
		t.Fatal("audit leaked secrets")
	}

	contents, err := os.ReadFile(filepath.Join(enrollStateDir, requestID+".json"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(contents, []byte("credential_password")) {
		t.Fatalf("state file retains credential_password: %s", contents)
	}
	var stored enrollRequest
	if err := json.Unmarshal(contents, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Status != "approved" || stored.ApprovedAt == "" || stored.CertificatePEM == "" ||
		stored.CertificateFingerprint == "" || stored.CredentialPKCS12 == "" {
		t.Fatalf("incomplete approved state: %s", contents)
	}
	if _, err := time.Parse("2006-01-02T15:04:05-07:00", stored.ApprovedAt); err != nil {
		t.Fatalf("approved_at not python iso: %q", stored.ApprovedAt)
	}

	// The p12 must decode and its key must match the certificate.
	p12, err := base64.StdEncoding.DecodeString(stored.CredentialPKCS12)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, certificate, chain, err := pkcs12.DecodeChain(p12, "Abcdef0123456789_-abcd")
	if err != nil {
		t.Fatalf("p12 decode: %v", err)
	}
	if privateKey == nil || certificate == nil || len(chain) != 1 {
		t.Fatalf("p12 contents incomplete: %v %v %d", privateKey, certificate, len(chain))
	}
	deviceKey := privateKey.(*ecdsa.PrivateKey)
	if !deviceKey.PublicKey.Equal(certificate.PublicKey) {
		t.Fatal("p12 key does not match certificate")
	}
	if !chain[0].Equal(fixture.issuerCert) {
		t.Fatal("p12 chain is not the issuer")
	}
	fingerprint := sha256.Sum256(certificate.Raw)
	if hex.EncodeToString(fingerprint[:]) != stored.CertificateFingerprint {
		t.Fatal("certificate fingerprint mismatch")
	}

	// Certificate fields must match the Python issuer.
	if certificate.Subject.CommonName != "my phone" || len(certificate.Subject.OrganizationalUnit) != 1 ||
		certificate.Subject.OrganizationalUnit[0] != stored.Fingerprint[:16] {
		t.Fatalf("unexpected subject: %+v", certificate.Subject)
	}
	if !bytes.Equal(certificate.RawIssuer, fixture.issuerCert.RawSubject) {
		t.Fatal("issuer name mismatch")
	}
	if certificate.KeyUsage != x509.KeyUsageDigitalSignature ||
		len(certificate.ExtKeyUsage) != 1 || certificate.ExtKeyUsage[0] != x509.ExtKeyUsageClientAuth ||
		!certificate.BasicConstraintsValid || certificate.IsCA {
		t.Fatalf("unexpected certificate extensions: %+v", certificate)
	}
	if got := certificate.SubjectKeyId; !bytes.Equal(got, ecKeyIdentifier(&deviceKey.PublicKey)) {
		t.Fatalf("unexpected SKI: %x", got)
	}
	if got := certificate.AuthorityKeyId; !bytes.Equal(got, ecKeyIdentifier(&fixture.issuerKey.PublicKey)) {
		t.Fatalf("unexpected AKI: %x", got)
	}
	if certificate.SignatureAlgorithm != x509.ECDSAWithSHA256 {
		t.Fatalf("unexpected signature algorithm: %v", certificate.SignatureAlgorithm)
	}
	if certificate.NotBefore.After(time.Now()) || certificate.NotAfter.Before(time.Now().Add(1824*24*time.Hour)) {
		t.Fatalf("unexpected validity window: %v %v", certificate.NotBefore, certificate.NotAfter)
	}

	// Subject DER must be the Python Name([CN, OU]) layout.
	expectedSubject := derName("my phone", stored.Fingerprint[:16])
	if !bytes.Equal(certificate.RawSubject, expectedSubject) {
		t.Fatalf("subject DER mismatch:\n%x\n%x", certificate.RawSubject, expectedSubject)
	}

	// Approved PEM on disk and trust bundle rebuilt.
	approvedPEM, err := os.ReadFile(filepath.Join(approvedDir, stored.CertificateFingerprint+".pem"))
	if err != nil {
		t.Fatal(err)
	}
	if string(approvedPEM) != stored.CertificatePEM {
		t.Fatal("approved pem mismatch")
	}
	ca, _ := os.ReadFile(bootstrapCAFile)
	trust, err := os.ReadFile(trustBundleFile)
	if err != nil {
		t.Fatal(err)
	}
	expectedTrust := string(ca) + stored.CertificatePEM
	if string(trust) != expectedTrust {
		t.Fatalf("trust bundle mismatch:\n%q\nwant\n%q", trust, expectedTrust)
	}
	if len(fixture.execCalls) != 2 ||
		fixture.execCalls[0][0] != "/usr/bin/caddy" || fixture.execCalls[0][1] != "validate" ||
		fixture.execCalls[1][0] != "/usr/bin/systemctl" || fixture.execCalls[1][2] != "caddy" {
		t.Fatalf("unexpected exec calls: %v", fixture.execCalls)
	}

	// Approving again prints the same approved item without re-issuing.
	again := &bytes.Buffer{}
	if err := runEnrollCLI([]string{"approve", code}, again); err != nil {
		t.Fatal(err)
	}
	var reprinted map[string]any
	if err := json.Unmarshal(again.Bytes(), &reprinted); err != nil || reprinted["certificate_fingerprint"] != stored.CertificateFingerprint {
		t.Fatalf("second approve changed state: %s", again.String())
	}
}

func TestApproveNotFoundAndExpired(t *testing.T) {
	setupCLI(t)
	if err := runEnrollCLI([]string{"approve", "UNKNOWN1"}, io.Discard); err == nil || err.Error() != "registration code not found or ambiguous" {
		t.Fatalf("expected not found error: %v", err)
	}

	created := createPending(t, "old phone", "Abcdef0123456789_-abcd")
	requestID := created.RequestID
	path := filepath.Join(enrollStateDir, requestID+".json")
	item, err := readEnrollRequest(path)
	if err != nil {
		t.Fatal(err)
	}
	item.ExpiresAt = isoUTC(time.Now().Add(-time.Hour))
	if err := writeEnrollRequest(path, item); err != nil {
		t.Fatal(err)
	}
	err = runEnrollCLI([]string{"approve", created.RegistrationCode}, io.Discard)
	if err == nil || err.Error() != "request expired" {
		t.Fatalf("expected expired error: %v", err)
	}
	item, _ = readEnrollRequest(path)
	if item.Status != "expired" {
		t.Fatalf("expected expired status: %s", item.Status)
	}
}

func TestApproveRequiresRoot(t *testing.T) {
	setupCLI(t)
	euidFunc = func() int { return 1000 }
	if err := runEnrollCLI([]string{"list"}, io.Discard); err == nil || err.Error() != "must run as root" {
		t.Fatalf("expected root error: %v", err)
	}
}

func TestRevoke(t *testing.T) {
	fixture := setupCLI(t)
	created := createPending(t, "revoke me", "Abcdef0123456789_-abcd")
	if err := runEnrollCLI([]string{"approve", created.RegistrationCode}, io.Discard); err != nil {
		t.Fatal(err)
	}
	item, _ := readEnrollRequest(filepath.Join(enrollStateDir, created.RequestID+".json"))
	stdout := &bytes.Buffer{}
	if err := runEnrollCLI([]string{"revoke", item.CertificateFingerprint}, stdout); err != nil {
		t.Fatal(err)
	}
	if stdout.String() != "revoked "+item.CertificateFingerprint+"\n" {
		t.Fatalf("unexpected revoke output: %q", stdout.String())
	}
	if _, err := os.Stat(filepath.Join(approvedDir, item.CertificateFingerprint+".pem")); !os.IsNotExist(err) {
		t.Fatal("approved pem should be deleted")
	}
	item, _ = readEnrollRequest(filepath.Join(enrollStateDir, created.RequestID+".json"))
	if item.Status != "revoked" || item.RevokedAt == "" {
		t.Fatalf("expected revoked state: %+v", item)
	}
	trust, _ := os.ReadFile(trustBundleFile)
	if strings.Contains(string(trust), item.CertificatePEM) {
		t.Fatal("trust bundle still contains revoked certificate")
	}
	if !strings.Contains(fixture.audit.String(), `"enrollment revoked"`) {
		t.Fatalf("audit missing revoke: %s", fixture.audit.String())
	}
	if err := runEnrollCLI([]string{"revoke", strings.Repeat("0", 64)}, io.Discard); err == nil || err.Error() != "approved fingerprint not found" {
		t.Fatalf("expected not found: %v", err)
	}
}

func TestRebuildTrustConcat(t *testing.T) {
	fixture := setupCLI(t)
	if err := os.WriteFile(bootstrapCAFile, []byte("CA-DATA"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(approvedDir, "a.pem"), []byte("A\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(approvedDir, "b.pem"), []byte("B"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := rebuildTrust(); err != nil {
		t.Fatal(err)
	}
	trust, _ := os.ReadFile(trustBundleFile)
	if string(trust) != "CA-DATA\nA\nB\n" {
		t.Fatalf("unexpected trust bundle: %q", trust)
	}
	if len(fixture.execCalls) != 2 {
		t.Fatalf("expected validate+reload: %v", fixture.execCalls)
	}

	// caddy validate failure must surface, and the bundle is already replaced.
	calls := 0
	execFunc = func(name string, args ...string) error {
		calls++
		return &commandError{cmd: name, err: os.ErrPermission}
	}
	if err := os.WriteFile(filepath.Join(approvedDir, "c.pem"), []byte("C\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := rebuildTrust(); err == nil {
		t.Fatal("expected caddy validate failure")
	}
	if calls != 1 {
		t.Fatalf("systemctl should not run after validate failure: %d", calls)
	}
	trust, _ = os.ReadFile(trustBundleFile)
	if string(trust) != "CA-DATA\nA\nB\nC\n" {
		t.Fatalf("bundle should be replaced before validate: %q", trust)
	}
}

func TestEnrollList(t *testing.T) {
	setupCLI(t)
	created := createPending(t, "listed", "Abcdef0123456789_-abcd")
	if err := runEnrollCLI([]string{"approve", created.RegistrationCode}, io.Discard); err != nil {
		t.Fatal(err)
	}
	createPending(t, "pending one", "Xbcdef0123456789_-abcd")
	stdout := &bytes.Buffer{}
	if err := runEnrollCLI([]string{"list"}, stdout); err != nil {
		t.Fatal(err)
	}
	text := stdout.String()
	for _, forbidden := range []string{"credential_password", "credential_pkcs12", "public_key_pem", "certificate_pem"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("list output leaks %s: %s", forbidden, text)
		}
	}
	var items []map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &items); err != nil || len(items) != 2 {
		t.Fatalf("unexpected list: %v %s", err, text)
	}
}
