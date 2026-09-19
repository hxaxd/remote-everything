package devicecore

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
	pairRequestPath = "/__remote_everything_pair"
	pairMaxBody     = 8 * 1024
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

func (service *Trust) pairDevice(invitation string, payload pairPayload) (pairResponse, error) {
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
	// Which node the device is being admitted to is what the invitation says, and
	// it is not something the device asks for: redeeming an invitation is what
	// puts that node on it. A renewal keeps the nodes the device already holds,
	// because renewing a credential is not a change of what it may reach.
	nodes := []string{invite.NodeID}
	if _, ok := service.nodeByID(invite.NodeID); !ok {
		return pairResponse{}, validationError("invitation_denied")
	}
	if invite.ReplacesFingerprint != "" {
		replaced, replacedErr := service.loadDeviceRecord(invite.ReplacesFingerprint)
		if replacedErr != nil || replaced.Status != "approved" {
			return pairResponse{}, validationError("invitation_denied")
		}
		nodes = replaced.Nodes
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
	issuerKey, issuerCertificate, err := loadIssuer(service.root)
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
		Schema: recordSchema, Kind: deviceKindCertificate, DeviceName: payload.DeviceName, CertificateFingerprint: fingerprint, Nodes: nodes,
		Status: "pending", CreatedAt: isoUTC(now), CertificateExpiresAt: isoUTC(certificate.NotAfter), PendingExpiresAt: invite.ExpiresAt,
	}
	if _, err := os.Stat(service.deviceRecordPath(fingerprint)); err == nil || !errors.Is(err, os.ErrNotExist) {
		return pairResponse{}, errors.New("device fingerprint collision")
	}
	if err := service.writeDeviceRecord(record); err != nil {
		return pairResponse{}, err
	}
	invite.UsedAt = isoUTC(now)
	invite.Kind = deviceKindCertificate
	invite.DeviceName = payload.DeviceName
	invite.CredentialPasswordHash = passwordHash
	invite.CertificateFingerprint = fingerprint
	invite.CredentialPKCS12 = credential
	if err := service.writeInvitation(invite); err != nil {
		_ = os.Remove(service.deviceRecordPath(fingerprint))
		return pairResponse{}, err
	}
	service.audit("device paired pending activation", "fingerprint", fingerprint, "device_name", payload.DeviceName)
	return pairResponse{
		OK: true, DeviceName: payload.DeviceName, CertificateFingerprint: fingerprint,
		CredentialFormat: "pkcs12", CredentialPKCS12: credential, PendingExpiresAt: record.PendingExpiresAt,
	}, nil
}

func (service *Trust) pairHTTPHandler(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost || request.RequestURI != pairRequestPath {
		gatewaycore.WriteJSON(writer, http.StatusNotFound, errorBody("not_found"))
		return
	}
	if !service.pairLimiter.allow(ClientAddress(request)) {
		gatewaycore.WriteJSON(writer, http.StatusTooManyRequests, errorBody("rate_limited"))
		return
	}
	if !service.pairLimiter.acquire() {
		gatewaycore.WriteJSON(writer, http.StatusServiceUnavailable, errorBody("server_busy"))
		return
	}
	defer service.pairLimiter.release()
	invitation := invitationFromRequest(request)
	if invitation == "" {
		time.Sleep(service.pairFailureDelay)
		gatewaycore.WriteJSON(writer, http.StatusUnauthorized, errorBody("invitation_denied"))
		return
	}
	if request.ContentLength <= 0 || request.ContentLength > pairMaxBody {
		gatewaycore.WriteJSON(writer, http.StatusBadRequest, errorBody("invalid_body"))
		return
	}
	decoder := json.NewDecoder(io.LimitReader(request.Body, pairMaxBody))
	decoder.DisallowUnknownFields()
	var payload pairPayload
	if decoder.Decode(&payload) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		gatewaycore.WriteJSON(writer, http.StatusBadRequest, errorBody("invalid_json"))
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
			gatewaycore.WriteJSON(writer, status, errorBody(string(validation)))
			return
		}
		service.log("pairing-server", "error", "pairing failed", "code", err.Error())
		gatewaycore.WriteJSON(writer, http.StatusInternalServerError, errorBody("pairing_failed"))
		return
	}
	gatewaycore.WriteJSON(writer, http.StatusOK, result)
}

// WebPairResult is the result of redeeming an invitation for a web browser client.
type WebPairResult struct {
	Fingerprint string   `json:"fingerprint"`
	DeviceName  string   `json:"device_name"`
	Status      string   `json:"status"`
	Nodes       []string `json:"nodes"`
}

// PairWebDevice redeems an invitation for a browser web client identified by
// the client id it keeps. The address is where the request came from, which
// the attempt is counted against: pairing is the one exchange where a
// credential can be guessed at, and a browser redeems an invitation at no
// lesser a door than an app does — the same limits, and the same delay before
// a refusal, guard both.
//
// A client id of a device this gateway already holds is itself the credential
// that browser authenticates with: the invitation was its admission, and the
// id is what it keeps instead of a credential file. Returning that device is
// how a browser that lost its session comes back, and it is why the
// invitation is read only when no such device exists yet. It answers with the
// code a refusal is written as, because the browser endpoint maps it to its
// own statuses.
func (service *Trust) PairWebDevice(address, invitation, clientID, deviceName string) (result WebPairResult, code string, err error) {
	clientID = strings.ToLower(strings.TrimSpace(clientID))
	if !validHex64.MatchString(clientID) {
		return WebPairResult{}, "invalid_client_id", errors.New("invalid client id")
	}
	deviceName = strings.TrimSpace(deviceName)
	if !validDeviceName(deviceName) {
		return WebPairResult{}, "invalid_device_name", errors.New("invalid device name")
	}
	if !service.pairLimiter.allow(address) {
		return WebPairResult{}, "rate_limited", errors.New("rate limited")
	}
	if !service.pairLimiter.acquire() {
		return WebPairResult{}, "server_busy", errors.New("server busy")
	}
	defer service.pairLimiter.release()
	result, code, err = service.pairWeb(invitation, clientID, deviceName)
	if code == "invitation_denied" {
		time.Sleep(service.pairFailureDelay)
	}
	return result, code, err
}

// pairWeb is the pairing of a browser client: it admits the device the client
// id names, or returns the device that id already has.
func (service *Trust) pairWeb(invitation, clientID, deviceName string) (WebPairResult, string, error) {
	sum := sha256.Sum256([]byte("web:" + clientID))
	fingerprint := hex.EncodeToString(sum[:])

	service.pairLock.Lock()
	defer service.pairLock.Unlock()

	if existing, err := service.loadDeviceRecord(fingerprint); err == nil && existing.Status != "revoked" {
		return WebPairResult{
			Fingerprint: fingerprint,
			DeviceName:  existing.DeviceName,
			Status:      existing.Status,
			Nodes:       existing.Nodes,
		}, "", nil
	}

	invite, err := service.loadInvitation(invitation)
	if err != nil {
		return WebPairResult{}, "invitation_denied", validationError("invitation_denied")
	}
	if invite.UsedAt != "" {
		return WebPairResult{}, "invitation_denied", validationError("invitation_denied")
	}
	nodes := []string{invite.NodeID}
	if _, ok := service.nodeByID(invite.NodeID); !ok {
		return WebPairResult{}, "invitation_denied", validationError("invitation_denied")
	}
	if invite.ReplacesFingerprint != "" {
		replaced, replacedErr := service.loadDeviceRecord(invite.ReplacesFingerprint)
		if replacedErr != nil || replaced.Status != "approved" {
			return WebPairResult{}, "invitation_denied", validationError("invitation_denied")
		}
		nodes = replaced.Nodes
	}

	now := time.Now().UTC()
	status := "pending"
	approvedAt := ""
	approvalRequestedAt := isoUTC(now)
	pendingExpiresAt := invite.ExpiresAt
	activatedAt := ""
	if service.approveOnRedemption {
		status = "approved"
		approvedAt = isoUTC(now)
		pendingExpiresAt = ""
		activatedAt = isoUTC(now)
	}
	record := deviceRecord{
		Schema: recordSchema, Kind: deviceKindWeb, DeviceName: deviceName, CertificateFingerprint: fingerprint, Nodes: nodes,
		Status: status, CreatedAt: isoUTC(now), PendingExpiresAt: pendingExpiresAt,
		ApprovalRequestedAt: approvalRequestedAt, ApprovedAt: approvedAt, ActivatedAt: activatedAt,
	}
	if err := service.writeDeviceRecord(record); err != nil {
		return WebPairResult{}, "pairing_failed", err
	}

	// A web redemption stores no credential: the browser keeps its client id
	// and identifies itself by it from here on, and there is nothing to hand
	// back that a browser could re-read.
	invite.UsedAt = isoUTC(now)
	invite.Kind = deviceKindWeb
	invite.DeviceName = deviceName
	invite.CertificateFingerprint = fingerprint
	if err := service.writeInvitation(invite); err != nil {
		_ = os.Remove(service.deviceRecordPath(fingerprint))
		return WebPairResult{}, "pairing_failed", err
	}

	service.audit("web device paired", "fingerprint", fingerprint, "device_name", deviceName, "status", status)
	return WebPairResult{
		Fingerprint: fingerprint,
		DeviceName:  deviceName,
		Status:      status,
		Nodes:       nodes,
	}, "", nil
}
