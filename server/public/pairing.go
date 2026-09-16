package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

const (
	pairRequestPath         = "/__remote_everything_pair"
	pairMaxBody             = 8 * 1024
	clientFingerprintHeader = "X-Remote-Everything-Client-Fingerprint"
)

var (
	credentialPasswordPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{20,64}$`)
)

type pairPayload struct {
	DeviceName         string `json:"device_name"`
	CredentialPassword string `json:"credential_password"`
}

type pairResponse struct {
	OK                     bool   `json:"ok"`
	DeviceName             string `json:"device_name"`
	CertificateFingerprint string `json:"certificate_fingerprint"`
	CredentialFormat       string `json:"credential_format"`
	CredentialPKCS12       string `json:"credential_pkcs12"`
	PendingExpiresAt       string `json:"pending_expires_at"`
}

type validationError string

func (errorValue validationError) Error() string { return string(errorValue) }

func validDeviceName(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" || len([]rune(value)) > 80 {
		return false
	}
	for _, character := range value {
		if character < 32 || character == 127 {
			return false
		}
	}
	return true
}

func invitationFromRequest(request *http.Request) string {
	value := request.Header.Get("Authorization")
	if !strings.HasPrefix(value, "Invitation ") {
		return ""
	}
	token := strings.TrimSpace(strings.TrimPrefix(value, "Invitation "))
	if len(token) != 43 {
		return ""
	}
	return token
}

func (service *publicService) pairDevice(invitation string, payload pairPayload) (pairResponse, error) {
	payload.DeviceName = strings.TrimSpace(payload.DeviceName)
	if !validDeviceName(payload.DeviceName) {
		return pairResponse{}, validationError("invalid_device_name")
	}
	if !credentialPasswordPattern.MatchString(payload.CredentialPassword) {
		return pairResponse{}, validationError("invalid_credential_password")
	}

	service.pairLock.Lock()
	defer service.pairLock.Unlock()
	invite, err := service.loadInvitation(invitation)
	if err != nil {
		return pairResponse{}, validationError("invitation_denied")
	}
	passwordDigest := sha256.Sum256([]byte(payload.CredentialPassword))
	passwordHash := hex.EncodeToString(passwordDigest[:])
	if invite.UsedAt != "" {
		if invite.DeviceName != payload.DeviceName || invite.CredentialPasswordHash != passwordHash {
			return pairResponse{}, validationError("invitation_denied")
		}
		return pairResponse{
			OK: true, DeviceName: invite.DeviceName, CertificateFingerprint: invite.CertificateFingerprint,
			CredentialFormat: "pkcs12", CredentialPKCS12: invite.CredentialPKCS12, PendingExpiresAt: invite.ExpiresAt,
		}, nil
	}
	issuerKey, issuerCertificate, err := loadIssuer(service.paths)
	if err != nil {
		return pairResponse{}, err
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return pairResponse{}, err
	}
	now := time.Now().UTC()
	certificate, fingerprint, err := issueDeviceCertificate(issuerKey, issuerCertificate, &privateKey.PublicKey, payload.DeviceName, now)
	if err != nil {
		return pairResponse{}, err
	}
	credential, err := encodePKCS12(privateKey, certificate, issuerCertificate, payload.CredentialPassword)
	if err != nil {
		return pairResponse{}, err
	}
	record := deviceRecord{
		Schema: recordSchema, DeviceName: payload.DeviceName, CertificateFingerprint: fingerprint,
		Status: "pending", CreatedAt: isoUTC(now), CertificateExpiresAt: isoUTC(certificate.NotAfter), PendingExpiresAt: invite.ExpiresAt,
	}
	if _, err := os.Stat(service.deviceRecordPath(fingerprint)); err == nil || !errors.Is(err, os.ErrNotExist) {
		return pairResponse{}, errors.New("device fingerprint collision")
	}
	if err := service.writeDeviceRecord(record); err != nil {
		return pairResponse{}, err
	}
	invite.UsedAt = isoUTC(now)
	invite.DeviceName = payload.DeviceName
	invite.CredentialPasswordHash = passwordHash
	invite.CertificateFingerprint = fingerprint
	invite.CredentialPKCS12 = credential
	if err := service.writeInvitation(invite); err != nil {
		_ = os.Remove(service.deviceRecordPath(fingerprint))
		return pairResponse{}, err
	}
	auditLine("device paired pending activation", "fingerprint", fingerprint, "device_name", payload.DeviceName)
	return pairResponse{
		OK: true, DeviceName: payload.DeviceName, CertificateFingerprint: fingerprint,
		CredentialFormat: "pkcs12", CredentialPKCS12: credential, PendingExpiresAt: record.PendingExpiresAt,
	}, nil
}

func writePairJSON(writer http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		body = []byte(`{"ok":false,"code":"internal_error"}`)
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store, max-age=0")
	writer.Header().Set("Pragma", "no-cache")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_, _ = writer.Write(body)
}

func (service *publicService) pairHTTPHandler(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost || request.RequestURI != pairRequestPath {
		writePairJSON(writer, http.StatusNotFound, errorBody("not_found"))
		return
	}
	if !service.pairLimiter.allow(clientIP(request)) {
		writePairJSON(writer, http.StatusTooManyRequests, errorBody("rate_limited"))
		return
	}
	if !service.pairLimiter.acquire() {
		writePairJSON(writer, http.StatusServiceUnavailable, errorBody("server_busy"))
		return
	}
	defer service.pairLimiter.release()
	invitation := invitationFromRequest(request)
	if invitation == "" {
		time.Sleep(service.pairFailureDelay)
		writePairJSON(writer, http.StatusUnauthorized, errorBody("invitation_denied"))
		return
	}
	if request.ContentLength <= 0 || request.ContentLength > pairMaxBody {
		writePairJSON(writer, http.StatusBadRequest, errorBody("invalid_body"))
		return
	}
	decoder := json.NewDecoder(io.LimitReader(request.Body, pairMaxBody))
	decoder.DisallowUnknownFields()
	var payload pairPayload
	if decoder.Decode(&payload) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		writePairJSON(writer, http.StatusBadRequest, errorBody("invalid_json"))
		return
	}
	result, err := service.pairDevice(invitation, payload)
	if err != nil {
		if validation, ok := err.(validationError); ok {
			status := http.StatusBadRequest
			if validation == "invitation_denied" {
				status = http.StatusUnauthorized
				time.Sleep(service.pairFailureDelay)
			}
			writePairJSON(writer, status, errorBody(string(validation)))
			return
		}
		logLine("pairing-server", "error", "pairing failed", "code", err.Error())
		writePairJSON(writer, http.StatusInternalServerError, errorBody("pairing_failed"))
		return
	}
	writePairJSON(writer, http.StatusOK, result)
}

func (service *publicService) newPairingServer() (*http.Server, error) {
	if err := os.MkdirAll(service.paths.devicesDir, 0o700); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(service.paths.invitesDir, 0o700); err != nil {
		return nil, err
	}
	if _, _, err := loadIssuer(service.paths); err != nil {
		return nil, err
	}
	if err := service.cleanupExpiredState(); err != nil {
		return nil, err
	}
	return gatewaycore.NewServer(service.config.PairingListen, http.HandlerFunc(service.pairHTTPHandler)), nil
}
