package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func setupEnrollment(t *testing.T) {
	t.Helper()
	directory := t.TempDir()
	enrollStateDir = filepath.Join(directory, "requests")
	bootstrapFingerprintFile = filepath.Join(directory, "bootstrap-fingerprint")
	if err := os.MkdirAll(enrollStateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bootstrapFingerprintFile, []byte("Bootstrap-ABC123\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	logOut = io.Discard
	t.Cleanup(func() {
		enrollStateDir = "/var/lib/kimi-enrollment/requests"
		bootstrapFingerprintFile = "/etc/kimi-gateway/bootstrap-fingerprint"
		logOut = os.Stdout
	})
}

type deviceProof struct {
	PEM        string
	Nonce      string
	Signature  string
	PrivateKey *ecdsa.PrivateKey
}

func makeProof(t *testing.T, deviceName string) deviceProof {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(proofMessage(deviceName, nonce))
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return deviceProof{
		PEM:        string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})),
		Nonce:      base64.StdEncoding.EncodeToString(nonce),
		Signature:  base64.StdEncoding.EncodeToString(signature),
		PrivateKey: key,
	}
}

func enrollPost(t *testing.T, payload string, fingerprint string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/__kimi_enroll/request", strings.NewReader(payload))
	if fingerprint != "" {
		request.Header.Set("X-Kimi-Bootstrap-Fingerprint", fingerprint)
	}
	recorder := httptest.NewRecorder()
	enrollHTTPHandler(recorder, request)
	return recorder
}

func enrollGet(t *testing.T, target string, fingerprint string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, target, nil)
	if fingerprint != "" {
		request.Header.Set("X-Kimi-Bootstrap-Fingerprint", fingerprint)
	}
	recorder := httptest.NewRecorder()
	enrollHTTPHandler(recorder, request)
	return recorder
}

func signWith(t *testing.T, key *ecdsa.PrivateKey, deviceName string) (string, string) {
	t.Helper()
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(proofMessage(deviceName, nonce))
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(nonce), base64.StdEncoding.EncodeToString(signature)
}

func jsonString(value string) string {
	encoded, _ := json.Marshal(value)
	return string(encoded)
}

func payloadWith(t *testing.T, proof deviceProof, deviceName string) string {
	t.Helper()
	return `{"device_name":` + jsonString(deviceName) + `,"public_key_pem":` + jsonString(proof.PEM) +
		`,"proof_nonce":"` + proof.Nonce + `","proof_signature":"` + proof.Signature +
		`","credential_delivery":"pkcs12","credential_password":"Abcdef0123456789_-abcd"}`
}

func validPayload(t *testing.T, deviceName string) string {
	t.Helper()
	return payloadWith(t, makeProof(t, deviceName), deviceName)
}

func responseCode(t *testing.T, recorder *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("response not json: %s", recorder.Body.String())
	}
	return body.Code
}

func TestEnrollCreateAndStatus(t *testing.T) {
	setupEnrollment(t)
	recorder := enrollPost(t, validPayload(t, "phone"), "bootstrap-abc123")
	if recorder.Code != 200 {
		t.Fatalf("status %d body %s", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Cache-Control") != "no-store, max-age=0" ||
		recorder.Header().Get("Pragma") != "no-cache" ||
		recorder.Header().Get("X-Content-Type-Options") != "nosniff" ||
		recorder.Header().Get("Content-Type") != "application/json; charset=utf-8" {
		t.Fatalf("missing security headers: %v", recorder.Header())
	}
	var created enrollRequest
	if err := json.Unmarshal(recorder.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Status != "pending" || len(created.RequestID) != 32 || len(created.RegistrationCode) != 8 ||
		len(created.Fingerprint) != 64 || created.DeviceName != "phone" {
		t.Fatalf("unexpected created state: %s", recorder.Body.String())
	}
	for _, char := range created.RegistrationCode {
		if !strings.ContainsRune(enrollCodeAlphabet, char) {
			t.Fatalf("registration code outside alphabet: %q", created.RegistrationCode)
		}
	}
	contents, err := os.ReadFile(filepath.Join(enrollStateDir, created.RequestID+".json"))
	if err != nil {
		t.Fatal(err)
	}
	var stored enrollRequest
	if err := json.Unmarshal(contents, &stored); err != nil {
		t.Fatal(err)
	}
	if stored.CredentialPassword != "Abcdef0123456789_-abcd" || stored.CredentialDelivery != "pkcs12" {
		t.Fatalf("password not stored for pkcs12 request: %s", contents)
	}
	expires, err := time.Parse("2006-01-02T15:04:05-07:00", stored.ExpiresAt)
	if err != nil {
		t.Fatalf("expires_at not python iso: %q", stored.ExpiresAt)
	}
	if until := time.Until(expires); until < 23*time.Hour || until > 24*time.Hour {
		t.Fatalf("expires_at not ~24h out: %v", until)
	}

	status := enrollGet(t, "/__kimi_enroll/status?id="+created.RequestID, "bootstrap-abc123")
	if status.Code != 200 {
		t.Fatalf("status lookup: %d %s", status.Code, status.Body.String())
	}
	var looked enrollRequest
	if err := json.Unmarshal(status.Body.Bytes(), &looked); err != nil {
		t.Fatal(err)
	}
	if looked.RequestID != created.RequestID || looked.Status != "pending" {
		t.Fatalf("unexpected status body: %s", status.Body.String())
	}
}

func TestEnrollInvalidSignature(t *testing.T) {
	setupEnrollment(t)
	proof := makeProof(t, "phone")
	other := makeProof(t, "phone")
	payload := `{"device_name":"phone","public_key_pem":` + jsonString(proof.PEM) +
		`,"proof_nonce":"` + proof.Nonce + `","proof_signature":"` + other.Signature +
		`","credential_delivery":"pkcs12","credential_password":"Abcdef0123456789_-abcd"}`
	recorder := enrollPost(t, payload, "bootstrap-abc123")
	if recorder.Code != 400 || responseCode(t, recorder) != "invalid_key_proof" {
		t.Fatalf("expected invalid_key_proof: %d %s", recorder.Code, recorder.Body.String())
	}

	// Same key, but the proof was made for a different device name.
	mismatched := makeProof(t, "laptop")
	payload = `{"device_name":"phone","public_key_pem":` + jsonString(mismatched.PEM) +
		`,"proof_nonce":"` + mismatched.Nonce + `","proof_signature":"` + mismatched.Signature +
		`","credential_delivery":"pkcs12","credential_password":"Abcdef0123456789_-abcd"}`
	if recorder := enrollPost(t, payload, "bootstrap-abc123"); responseCode(t, recorder) != "invalid_key_proof" {
		t.Fatalf("expected invalid_key_proof for name mismatch: %s", recorder.Body.String())
	}
}

func TestEnrollInvalidPublicKey(t *testing.T) {
	setupEnrollment(t)
	build := func(pemText string) string {
		return `{"device_name":"phone","public_key_pem":` + jsonString(pemText) +
			`,"proof_nonce":"` + base64.StdEncoding.EncodeToString(make([]byte, 32)) +
			`","proof_signature":"` + base64.StdEncoding.EncodeToString(make([]byte, 64)) +
			`","credential_delivery":"pkcs12","credential_password":"Abcdef0123456789_-abcd"}`
	}
	if recorder := enrollPost(t, build("not a pem"), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_public_key" {
		t.Fatalf("expected invalid_public_key: %s", recorder.Body.String())
	}
	if recorder := enrollPost(t, build(strings.Repeat("A", 9*1024)), "bootstrap-abc123"); responseCode(t, recorder) != "public_key_too_large" {
		t.Fatalf("expected public_key_too_large: %s", recorder.Body.String())
	}
	rsaKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	rsaDER, _ := x509.MarshalPKIXPublicKey(&rsaKey.PublicKey)
	rsaPEM := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: rsaDER}))
	if recorder := enrollPost(t, build(rsaPEM), "bootstrap-abc123"); responseCode(t, recorder) != "unsupported_key" {
		t.Fatalf("expected unsupported_key: %s", recorder.Body.String())
	}
}

func TestEnrollInvalidProof(t *testing.T) {
	setupEnrollment(t)
	proof := makeProof(t, "phone")
	build := func(nonce, signature string) string {
		return `{"device_name":"phone","public_key_pem":` + jsonString(proof.PEM) +
			`,"proof_nonce":"` + nonce + `","proof_signature":"` + signature +
			`","credential_delivery":"pkcs12","credential_password":"Abcdef0123456789_-abcd"}`
	}
	if recorder := enrollPost(t, build("!!!", proof.Signature), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_proof_encoding" {
		t.Fatalf("expected invalid_proof_encoding: %s", recorder.Body.String())
	}
	shortNonce := base64.StdEncoding.EncodeToString(make([]byte, 8))
	if recorder := enrollPost(t, build(shortNonce, proof.Signature), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_proof_size" {
		t.Fatalf("expected invalid_proof_size: %s", recorder.Body.String())
	}
}

func TestEnrollInvalidPasswordAndDelivery(t *testing.T) {
	setupEnrollment(t)
	proof := makeProof(t, "phone")
	build := func(delivery, password string) string {
		return `{"device_name":"phone","public_key_pem":` + jsonString(proof.PEM) +
			`,"proof_nonce":"` + proof.Nonce + `","proof_signature":"` + proof.Signature +
			`","credential_delivery":"` + delivery + `","credential_password":"` + password + `"}`
	}
	if recorder := enrollPost(t, build("pkcs12", "short"), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_credential_password" {
		t.Fatalf("expected invalid_credential_password: %s", recorder.Body.String())
	}
	if recorder := enrollPost(t, build("pkcs12", "has space inside password"), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_credential_password" {
		t.Fatalf("expected invalid_credential_password for bad chars: %s", recorder.Body.String())
	}
	if recorder := enrollPost(t, build("bogus", ""), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_credential_delivery" {
		t.Fatalf("expected invalid_credential_delivery: %s", recorder.Body.String())
	}
	if recorder := enrollPost(t, build("certificate", ""), "bootstrap-abc123"); responseCode(t, recorder) != "invalid_credential_delivery" {
		t.Fatalf("expected invalid_credential_delivery for legacy certificate mode: %s", recorder.Body.String())
	}
}

func TestEnrollInvalidDeviceName(t *testing.T) {
	setupEnrollment(t)
	for _, name := range []string{"", "   ", strings.Repeat("a", 81), "bad\x01name", strings.Repeat("中", 81)} {
		recorder := enrollPost(t, validPayload(t, name), "bootstrap-abc123")
		if responseCode(t, recorder) != "invalid_device_name" {
			t.Fatalf("expected invalid_device_name for %q: %s", name, recorder.Body.String())
		}
	}
	if recorder := enrollPost(t, validPayload(t, strings.Repeat("中", 80)), "bootstrap-abc123"); recorder.Code != 200 {
		t.Fatalf("80 rune name should pass: %s", recorder.Body.String())
	}
}

func TestEnrollAuthAndRouting(t *testing.T) {
	setupEnrollment(t)
	if recorder := enrollPost(t, validPayload(t, "phone"), ""); recorder.Code != 403 || responseCode(t, recorder) != "bootstrap_forbidden" {
		t.Fatalf("expected bootstrap_forbidden: %d", recorder.Code)
	}
	if recorder := enrollPost(t, validPayload(t, "phone"), "wrong"); recorder.Code != 403 {
		t.Fatalf("expected 403 for wrong fingerprint: %d", recorder.Code)
	}
	// POST path check happens before auth.
	request := httptest.NewRequest(http.MethodPost, "/other", strings.NewReader("{}"))
	recorder := httptest.NewRecorder()
	enrollHTTPHandler(recorder, request)
	if recorder.Code != 404 || responseCode(t, recorder) != "not_found" {
		t.Fatalf("expected not_found: %d", recorder.Code)
	}
	// GET auth happens before path check.
	if recorder := enrollGet(t, "/other", ""); recorder.Code != 403 {
		t.Fatalf("expected 403 before path check: %d", recorder.Code)
	}
	if recorder := enrollGet(t, "/other", "bootstrap-abc123"); recorder.Code != 404 || responseCode(t, recorder) != "not_found" {
		t.Fatalf("expected not_found: %d", recorder.Code)
	}
	if recorder := enrollGet(t, "/__kimi_enroll/status?id=missing", "bootstrap-abc123"); recorder.Code != 404 || responseCode(t, recorder) != "request_not_found" {
		t.Fatalf("expected request_not_found: %d", recorder.Code)
	}
	if recorder := enrollGet(t, "/__kimi_enroll/status?id=../etc", "bootstrap-abc123"); recorder.Code != 404 || responseCode(t, recorder) != "request_not_found" {
		t.Fatalf("expected request_not_found for traversal: %d", recorder.Code)
	}
}

func TestEnrollBodyValidation(t *testing.T) {
	setupEnrollment(t)
	tooLarge := strings.Repeat("x", 33*1024)
	if recorder := enrollPost(t, tooLarge, "bootstrap-abc123"); recorder.Code != 400 || responseCode(t, recorder) != "invalid_body" {
		t.Fatalf("expected invalid_body: %d", recorder.Code)
	}
	if recorder := enrollPost(t, "{bad json", "bootstrap-abc123"); recorder.Code != 400 || responseCode(t, recorder) != "invalid_json" {
		t.Fatalf("expected invalid_json: %d", recorder.Code)
	}
	if recorder := enrollPost(t, `["array"]`, "bootstrap-abc123"); recorder.Code != 400 || responseCode(t, recorder) != "invalid_json" {
		t.Fatalf("expected invalid_json for array: %d", recorder.Code)
	}
}

func TestEnrollDedupAndExpiredPending(t *testing.T) {
	setupEnrollment(t)
	proof := makeProof(t, "phone")
	freshProof := func() deviceProof {
		nonce, signature := signWith(t, proof.PrivateKey, "phone")
		return deviceProof{PEM: proof.PEM, Nonce: nonce, Signature: signature}
	}
	first := enrollPost(t, payloadWith(t, freshProof(), "phone"), "bootstrap-abc123")
	if first.Code != 200 {
		t.Fatalf("first: %s", first.Body.String())
	}
	var created enrollRequest
	_ = json.Unmarshal(first.Body.Bytes(), &created)
	second := enrollPost(t, payloadWith(t, freshProof(), "phone"), "bootstrap-abc123")
	var again enrollRequest
	_ = json.Unmarshal(second.Body.Bytes(), &again)
	if again.RequestID != created.RequestID || again.RegistrationCode != created.RegistrationCode {
		t.Fatalf("dedup should return the same request: %s vs %s", first.Body.String(), second.Body.String())
	}

	// Expire the stored request; a new registration must create a fresh one.
	path := filepath.Join(enrollStateDir, created.RequestID+".json")
	contents, _ := os.ReadFile(path)
	var stored enrollRequest
	_ = json.Unmarshal(contents, &stored)
	stored.ExpiresAt = isoUTC(time.Now().Add(-time.Hour))
	updated, _ := json.Marshal(stored)
	if err := os.WriteFile(path, updated, 0o600); err != nil {
		t.Fatal(err)
	}
	third := enrollPost(t, payloadWith(t, freshProof(), "phone"), "bootstrap-abc123")
	var fresh enrollRequest
	_ = json.Unmarshal(third.Body.Bytes(), &fresh)
	if fresh.RequestID == created.RequestID {
		t.Fatalf("expired pending should not be returned: %s", third.Body.String())
	}
}

func TestSweepExpiredRequests(t *testing.T) {
	setupEnrollment(t)
	writeState := func(name, status, expiresAt string) {
		item := &enrollRequest{
			RequestID: name, RegistrationCode: "CODE" + name, DeviceName: "d", Fingerprint: name,
			PublicKeyPEM: "pem", CredentialDelivery: "pkcs12", Status: status,
			CreatedAt: isoUTC(time.Now().Add(-26 * time.Hour)), ExpiresAt: expiresAt,
		}
		if err := writeEnrollRequest(filepath.Join(enrollStateDir, name+".json"), item); err != nil {
			t.Fatal(err)
		}
	}
	writeState("expired", "pending", isoUTC(time.Now().Add(-time.Hour)))
	writeState("fresh", "pending", isoUTC(time.Now().Add(time.Hour)))
	writeState("approved", "approved", isoUTC(time.Now().Add(-time.Hour)))
	writeState("broken", "pending", "not-a-date")
	sweepExpiredEnrollRequests()
	for _, name := range []string{"expired", "broken"} {
		if _, err := os.Stat(filepath.Join(enrollStateDir, name+".json")); !os.IsNotExist(err) {
			t.Fatalf("%s should be swept", name)
		}
	}
	for _, name := range []string{"fresh", "approved"} {
		if _, err := os.Stat(filepath.Join(enrollStateDir, name+".json")); err != nil {
			t.Fatalf("%s should be kept: %v", name, err)
		}
	}
}
