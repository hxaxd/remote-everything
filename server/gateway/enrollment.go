package main

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	enrollListenAddr      = "127.0.0.1:58631"
	enrollMaxBody         = 32 * 1024
	enrollCodeAlphabet    = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	enrollSweepInterval   = time.Hour
	enrollRequestLifetime = 24 * time.Hour
	enrollRequestPath     = "/__kimi_enroll/request"
	enrollStatusPath      = "/__kimi_enroll/status"
)

var (
	enrollLock    sync.Mutex
	enrollIDChars = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)
)

type enrollRequest struct {
	RequestID              string `json:"request_id"`
	RegistrationCode       string `json:"registration_code"`
	DeviceName             string `json:"device_name"`
	Fingerprint            string `json:"fingerprint"`
	PublicKeyPEM           string `json:"public_key_pem"`
	CredentialDelivery     string `json:"credential_delivery"`
	Status                 string `json:"status"`
	CreatedAt              string `json:"created_at"`
	ExpiresAt              string `json:"expires_at"`
	CredentialPassword     string `json:"credential_password,omitempty"`
	CertificatePEM         string `json:"certificate_pem,omitempty"`
	CertificateFingerprint string `json:"certificate_fingerprint,omitempty"`
	CredentialPKCS12       string `json:"credential_pkcs12,omitempty"`
	ApprovedAt             string `json:"approved_at,omitempty"`
	RevokedAt              string `json:"revoked_at,omitempty"`
}

type publicStateJSON struct {
	OK                     bool   `json:"ok"`
	Status                 string `json:"status"`
	RequestID              string `json:"request_id"`
	RegistrationCode       string `json:"registration_code"`
	Fingerprint            string `json:"fingerprint"`
	DeviceName             string `json:"device_name"`
	CertificatePEM         string `json:"certificate_pem,omitempty"`
	CertificateFingerprint string `json:"certificate_fingerprint,omitempty"`
	CredentialFormat       string `json:"credential_format,omitempty"`
	CredentialPKCS12       string `json:"credential_pkcs12,omitempty"`
}

func isoUTC(value time.Time) string {
	return value.UTC().Truncate(time.Second).Format("2006-01-02T15:04:05-07:00")
}

func expectedBootstrapFingerprint() (string, error) {
	contents, err := os.ReadFile(bootstrapFingerprintFile)
	if err != nil {
		return "", err
	}
	return strings.ToLower(strings.TrimSpace(string(contents))), nil
}

func proofMessage(deviceName string, nonce []byte) []byte {
	message := make([]byte, 0, len(deviceName)+len(nonce)+24)
	message = append(message, "KIMI-REMOTE-ENROLL-V1\x00"...)
	message = append(message, deviceName...)
	message = append(message, 0)
	return append(message, nonce...)
}

type validationError string

func (e validationError) Error() string { return string(e) }

func validateDeviceKey(deviceName, publicKeyPEM, nonceB64, signatureB64 string) (string, string, error) {
	if len(publicKeyPEM) > 8*1024 {
		return "", "", validationError("public_key_too_large")
	}
	ascii := true
	for index := 0; index < len(publicKeyPEM); index++ {
		if publicKeyPEM[index] > 127 {
			ascii = false
			break
		}
	}
	var publicKey *ecdsa.PublicKey
	var keyErr error
	if ascii {
		if block, _ := pem.Decode([]byte(publicKeyPEM)); block != nil {
			publicKey, keyErr = parseDevicePublicKey(block.Bytes)
		}
	}
	if publicKey == nil {
		if errors.Is(keyErr, errUnsupportedKey) {
			return "", "", validationError("unsupported_key")
		}
		return "", "", validationError("invalid_public_key")
	}
	nonce, nonceErr := base64.StdEncoding.DecodeString(nonceB64)
	signature, signatureErr := base64.StdEncoding.DecodeString(signatureB64)
	if nonceErr != nil || signatureErr != nil {
		return "", "", validationError("invalid_proof_encoding")
	}
	if len(nonce) < 24 || len(nonce) > 64 || len(signature) < 8 || len(signature) > 256 {
		return "", "", validationError("invalid_proof_size")
	}
	digest := sha256.Sum256(proofMessage(deviceName, nonce))
	if !ecdsa.VerifyASN1(publicKey, digest[:], signature) {
		return "", "", validationError("invalid_key_proof")
	}
	der, err := x509.MarshalPKIXPublicKey(publicKey)
	if err != nil {
		return "", "", validationError("invalid_public_key")
	}
	canonical := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	fingerprint := sha256.Sum256(der)
	return canonical, hex.EncodeToString(fingerprint[:]), nil
}

func enrollRequestFiles() []string {
	matches, _ := filepath.Glob(filepath.Join(enrollStateDir, "*.json"))
	return matches
}

func readEnrollRequest(path string) (*enrollRequest, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var item enrollRequest
	if err := json.Unmarshal(contents, &item); err != nil {
		return nil, err
	}
	return &item, nil
}

func writeEnrollRequest(path string, item *enrollRequest) error {
	contents, err := json.Marshal(item)
	if err != nil {
		return err
	}
	temporary := strings.TrimSuffix(path, ".json") + ".json.tmp"
	if err := os.WriteFile(temporary, contents, 0o600); err != nil {
		return err
	}
	_ = os.Chmod(temporary, 0o600)
	return replaceFile(temporary, path)
}

func enrollParseTime(value string) (time.Time, bool) {
	parsed, err := time.Parse("2006-01-02T15:04:05-07:00", value)
	if err != nil {
		return time.Time{}, false
	}
	return parsed, true
}

func isEnrollExpired(item *enrollRequest) bool {
	expires, ok := enrollParseTime(item.ExpiresAt)
	return !ok || !expires.After(time.Now())
}

func findExistingEnrollRequest(fingerprint, delivery string) *enrollRequest {
	for _, path := range enrollRequestFiles() {
		item, err := readEnrollRequest(path)
		if err != nil {
			continue
		}
		existingDelivery := item.CredentialDelivery
		if existingDelivery == "" {
			existingDelivery = "pkcs12"
		}
		if item.Fingerprint == fingerprint &&
			existingDelivery == delivery &&
			(item.Status == "pending" || item.Status == "approved") &&
			!(item.Status == "pending" && isEnrollExpired(item)) {
			return item
		}
	}
	return nil
}

func sweepExpiredEnrollRequests() {
	enrollLock.Lock()
	defer enrollLock.Unlock()
	for _, path := range enrollRequestFiles() {
		item, err := readEnrollRequest(path)
		if err != nil {
			continue
		}
		if item.Status != "pending" {
			continue
		}
		if isEnrollExpired(item) {
			_ = os.Remove(path)
		}
	}
}

func enrollSweeper() {
	for {
		time.Sleep(enrollSweepInterval)
		sweepExpiredEnrollRequests()
	}
}

func publicEnrollState(item *enrollRequest) publicStateJSON {
	result := publicStateJSON{
		OK:               true,
		Status:           item.Status,
		RequestID:        item.RequestID,
		RegistrationCode: item.RegistrationCode,
		Fingerprint:      item.Fingerprint,
		DeviceName:       item.DeviceName,
	}
	if item.Status == "approved" {
		result.CertificatePEM = item.CertificatePEM
		result.CertificateFingerprint = item.CertificateFingerprint
		if item.CredentialDelivery == "pkcs12" {
			result.CredentialFormat = "pkcs12"
			result.CredentialPKCS12 = item.CredentialPKCS12
		}
	}
	return result
}

var enrollPasswordPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{20,32}$`)

func createEnrollRequest(deviceName, publicKeyPEM, nonceB64, signatureB64, delivery, password string) (publicStateJSON, error) {
	deviceName = strings.TrimSpace(deviceName)
	if deviceName == "" || len([]rune(deviceName)) > 80 {
		return publicStateJSON{}, validationError("invalid_device_name")
	}
	for _, char := range deviceName {
		if char < 32 {
			return publicStateJSON{}, validationError("invalid_device_name")
		}
	}
	canonicalPublicKey, fingerprint, err := validateDeviceKey(deviceName, publicKeyPEM, nonceB64, signatureB64)
	if err != nil {
		return publicStateJSON{}, err
	}
	if delivery != "pkcs12" {
		return publicStateJSON{}, validationError("invalid_credential_delivery")
	}
	if !enrollPasswordPattern.MatchString(password) {
		return publicStateJSON{}, validationError("invalid_credential_password")
	}

	enrollLock.Lock()
	defer enrollLock.Unlock()
	if existing := findExistingEnrollRequest(fingerprint, delivery); existing != nil {
		return publicEnrollState(existing), nil
	}

	requestID, err := randomToken(24)
	if err != nil {
		return publicStateJSON{}, err
	}
	code, err := randomRegistrationCode()
	if err != nil {
		return publicStateJSON{}, err
	}
	now := time.Now()
	item := &enrollRequest{
		RequestID:          requestID,
		RegistrationCode:   code,
		DeviceName:         deviceName,
		Fingerprint:        fingerprint,
		PublicKeyPEM:       canonicalPublicKey,
		CredentialDelivery: delivery,
		Status:             "pending",
		CreatedAt:          isoUTC(now),
		ExpiresAt:          isoUTC(now.Add(enrollRequestLifetime)),
		CredentialPassword: password,
	}
	if err := writeEnrollRequest(filepath.Join(enrollStateDir, requestID+".json"), item); err != nil {
		return publicStateJSON{}, err
	}
	return publicEnrollState(item), nil
}

func randomToken(length int) (string, error) {
	buffer := make([]byte, length)
	if _, err := io.ReadFull(rand.Reader, buffer); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}

func randomRegistrationCode() (string, error) {
	var out strings.Builder
	limit := big.NewInt(int64(len(enrollCodeAlphabet)))
	for out.Len() < 8 {
		index, err := rand.Int(rand.Reader, limit)
		if err != nil {
			return "", err
		}
		out.WriteByte(enrollCodeAlphabet[index.Int64()])
	}
	return out.String(), nil
}

func lookupEnrollRequest(requestID string) *enrollRequest {
	if requestID == "" || !enrollIDChars.MatchString(requestID) {
		return nil
	}
	path := filepath.Join(enrollStateDir, requestID+".json")
	if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
		return nil
	}
	item, err := readEnrollRequest(path)
	if err != nil {
		return nil
	}
	return item
}

func writeEnrollJSON(writer http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		body = []byte(`{"ok":false,"code":"internal_error"}`)
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Content-Length", strconv.Itoa(len(body)))
	writer.Header().Set("Cache-Control", "no-store, max-age=0")
	writer.Header().Set("Pragma", "no-cache")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_, _ = writer.Write(body)
}

func enrollBootstrapAuthorized(request *http.Request) bool {
	expected, err := expectedBootstrapFingerprint()
	if err != nil {
		logLine("enrollment-server", "error", "bootstrap fingerprint unavailable", "path", request.URL.Path)
		return false
	}
	supplied := strings.ToLower(strings.TrimSpace(request.Header.Get("X-Kimi-Bootstrap-Fingerprint")))
	return subtle.ConstantTimeCompare([]byte(supplied), []byte(expected)) == 1
}

func enrollLog(code, requestID string) {
	if len(requestID) > 8 {
		requestID = requestID[:8]
	}
	logLine("enrollment-server", "info", "enrollment request", "code", code, "request_id", requestID)
}

func enrollHTTPHandler(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodPost:
		enrollPostHandler(writer, request)
	case http.MethodGet:
		enrollGetHandler(writer, request)
	default:
		writer.WriteHeader(http.StatusNotImplemented)
	}
}

type enrollPayload struct {
	DeviceName         string `json:"device_name"`
	PublicKeyPEM       string `json:"public_key_pem"`
	ProofNonce         string `json:"proof_nonce"`
	ProofSignature     string `json:"proof_signature"`
	CredentialDelivery string `json:"credential_delivery"`
	CredentialPassword string `json:"credential_password"`
}

func enrollPostHandler(writer http.ResponseWriter, request *http.Request) {
	if request.RequestURI != enrollRequestPath {
		writeEnrollJSON(writer, http.StatusNotFound, errorBody("not_found"))
		return
	}
	if !enrollBootstrapAuthorized(request) {
		writeEnrollJSON(writer, http.StatusForbidden, errorBody("bootstrap_forbidden"))
		return
	}
	length := request.ContentLength
	if length <= 0 || length > enrollMaxBody {
		writeEnrollJSON(writer, http.StatusBadRequest, errorBody("invalid_body"))
		return
	}
	body, _ := io.ReadAll(io.LimitReader(request.Body, length))
	var payload enrollPayload
	if err := json.Unmarshal(body, &payload); err != nil {
		writeEnrollJSON(writer, http.StatusBadRequest, errorBody("invalid_json"))
		return
	}
	delivery := payload.CredentialDelivery
	if delivery == "" {
		delivery = "pkcs12"
	}
	result, err := createEnrollRequest(
		payload.DeviceName,
		payload.PublicKeyPEM,
		payload.ProofNonce,
		payload.ProofSignature,
		delivery,
		payload.CredentialPassword,
	)
	if err != nil {
		code := "invalid_json"
		if validation, ok := err.(validationError); ok {
			code = string(validation)
		} else {
			logLine("enrollment-server", "error", "request creation failed", "code", err.Error())
		}
		writeEnrollJSON(writer, http.StatusBadRequest, errorBody(code))
		return
	}
	enrollLog("created", result.RequestID)
	writeEnrollJSON(writer, http.StatusOK, result)
}

func enrollGetHandler(writer http.ResponseWriter, request *http.Request) {
	if !enrollBootstrapAuthorized(request) {
		writeEnrollJSON(writer, http.StatusForbidden, errorBody("bootstrap_forbidden"))
		return
	}
	rawPath := request.RequestURI
	if index := strings.IndexByte(rawPath, '?'); index >= 0 {
		rawPath = rawPath[:index]
	}
	if rawPath != enrollStatusPath {
		writeEnrollJSON(writer, http.StatusNotFound, errorBody("not_found"))
		return
	}
	requestID := ""
	if index := strings.IndexByte(request.RequestURI, '?'); index >= 0 {
		if values, err := url.ParseQuery(request.RequestURI[index+1:]); err == nil {
			if list, ok := values["id"]; ok && len(list) > 0 {
				requestID = list[0]
			}
		}
	}
	item := lookupEnrollRequest(requestID)
	if item == nil {
		writeEnrollJSON(writer, http.StatusNotFound, errorBody("request_not_found"))
		return
	}
	writeEnrollJSON(writer, http.StatusOK, publicEnrollState(item))
}

func serveEnrollment() {
	if err := os.MkdirAll(enrollStateDir, 0o755); err != nil {
		logLine("enrollment-server", "error", "state directory unavailable", "path", enrollStateDir)
		os.Exit(1)
	}
	go enrollSweeper()
	server := &http.Server{
		Addr:              enrollListenAddr,
		Handler:           http.HandlerFunc(enrollHTTPHandler),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	logLine("enrollment-server", "info", "listening", "path", enrollListenAddr)
	if err := server.ListenAndServe(); err != nil {
		logLine("enrollment-server", "error", "server stopped", "code", err.Error())
		os.Exit(1)
	}
}
