package devicecore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"software.sslmate.com/src/go-pkcs12"
)

// newNodeStub is a gateway surface whose node answers the control endpoint with
// one app, which is what activation requires before it approves a device.
func newNodeStub(t *testing.T) *gatewaycore.Gateway {
	t.Helper()
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/__local_remote_control" {
			_, _ = io.WriteString(writer, "proxied")
			return
		}
		var input map[string]string
		_ = json.NewDecoder(request.Body).Decode(&input)
		if input["action"] == "list" {
			_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[{"id":"fixture","name":"Fixture","description":"","icon":"F","accent":"#2563eb","computer_connected":true,"enabled":true,"running":true,"code":"ready"}]}`)
			return
		}
		_, _ = io.WriteString(writer, `{"ok":true,"action":"`+input["action"]+`","computer_connected":true,"enabled":true,"running":true,"code":"ready"}`)
	}))
	t.Cleanup(node.Close)
	gateway, err := gatewaycore.New(node.URL, strings.Repeat("01", 32))
	if err != nil {
		t.Fatal(err)
	}
	return gateway
}

func setupPublicTest(t *testing.T) *Trust {
	t.Helper()
	trust, err := Open(Config{
		Root: t.TempDir(), InstallationID: strings.Repeat("a", 64), Mode: "public",
		Origin: "https://remote.example.com", Node: newNodeStub(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	trust.pairFailureDelay = 0
	return trust
}

func createInvitation(t *testing.T, service *Trust) string {
	t.Helper()
	var output bytes.Buffer
	if err := service.issueInvitation(10*time.Minute, "Test PC", "", &output); err != nil {
		t.Fatal(err)
	}
	var result invitationResult
	if err := json.Unmarshal(output.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result.Invitation
}

func pairRequest(t *testing.T, service *Trust, invitation, body string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, pairRequestPath, strings.NewReader(body))
	request.Header.Set("Authorization", "Invitation "+invitation)
	recorder := httptest.NewRecorder()
	service.pairHTTPHandler(recorder, request)
	return recorder
}

func pairFixture(t *testing.T, service *Trust) pairResponse {
	t.Helper()
	invitation := createInvitation(t, service)
	recorder := pairRequest(t, service, invitation, `{"device_name":"Test Phone","credential_password":"credential-password-123"}`)
	if recorder.Code != http.StatusOK {
		t.Fatalf("pairing failed: %d %s", recorder.Code, recorder.Body.String())
	}
	var paired pairResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &paired); err != nil {
		t.Fatal(err)
	}
	return paired
}

func approvePending(t *testing.T, service *Trust, fingerprint string) {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, "/__remote_everything_activate", nil)
	request.Header.Set(clientFingerprintHeader, fingerprint)
	if _, code, err := service.activateDevice(request); err == nil || code != "approval_pending" {
		t.Fatalf("approval request failed: %s %v", code, err)
	}
	if err := service.deviceApprove(fingerprint, io.Discard); err != nil {
		t.Fatalf("approval failed: %v", err)
	}
}

func activateApproved(t *testing.T, service *Trust, fingerprint string) {
	t.Helper()
	approvePending(t, service, fingerprint)
	request := httptest.NewRequest(http.MethodPost, "/__remote_everything_activate", nil)
	request.Header.Set(clientFingerprintHeader, fingerprint)
	if _, code, err := service.activateDevice(request); err != nil || code != "" {
		t.Fatalf("activation failed: %s %v", code, err)
	}
	var repeated bytes.Buffer
	if err := service.deviceApprove(fingerprint, &repeated); err != nil || !strings.Contains(repeated.String(), `"changed":false`) {
		t.Fatalf("repeat approval is not idempotent: %s %v", repeated.String(), err)
	}
}

func TestInvitationPairingIsSingleUseAndPending(t *testing.T) {
	service := setupPublicTest(t)
	if recorder := pairRequest(t, service, "bad", `{}`); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("invalid invitation status = %d", recorder.Code)
	}
	invitation := createInvitation(t, service)
	body := `{"device_name":"Test Phone","credential_password":"credential-password-123"}`
	first := pairRequest(t, service, invitation, body)
	if first.Code != http.StatusOK {
		t.Fatalf("pairing failed: %d %s", first.Code, first.Body.String())
	}
	second := pairRequest(t, service, invitation, body)
	if second.Code != http.StatusOK || second.Body.String() != first.Body.String() {
		t.Fatalf("idempotent pairing replay changed response: %d %s", second.Code, second.Body.String())
	}
	if changed := pairRequest(t, service, invitation, `{"device_name":"Other Phone","credential_password":"credential-password-456"}`); changed.Code != http.StatusUnauthorized {
		t.Fatalf("invitation enrolled a second transaction: %d", changed.Code)
	}
	var paired pairResponse
	if err := json.Unmarshal(first.Body.Bytes(), &paired); err != nil {
		t.Fatal(err)
	}
	record, err := service.loadDeviceRecord(paired.CertificateFingerprint)
	if err != nil || record.Status != "pending" || record.PendingExpiresAt == "" {
		t.Fatalf("unexpected pending record: %+v %v", record, err)
	}
	credential, err := base64.StdEncoding.DecodeString(paired.CredentialPKCS12)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, certificate, chain, err := pkcs12.DecodeChain(credential, "credential-password-123")
	if err != nil || privateKey == nil || certificate == nil || len(chain) != 1 {
		t.Fatalf("invalid PKCS12 credential: %v", err)
	}
}

func TestActivationCommitsOnlyAfterNodeValidationAndIsIdempotent(t *testing.T) {
	service := setupPublicTest(t)
	paired := pairFixture(t, service)
	token := strings.Repeat("01", 32)
	nodeAvailable := false
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if !nodeAvailable {
			writer.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if request.Header.Get("Authorization") != "Bearer "+token {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[]}`)
	}))
	defer node.Close()
	service.node, _ = gatewaycore.New(node.URL, token)
	request := httptest.NewRequest(http.MethodPost, "/__remote_everything_activate", nil)
	request.Header.Set(clientFingerprintHeader, paired.CertificateFingerprint)
	if _, code, err := service.activateDevice(request); err == nil || code != "approval_pending" {
		t.Fatalf("unapproved activation unexpectedly succeeded: %s %v", code, err)
	}
	if err := service.deviceApprove(paired.CertificateFingerprint, io.Discard); err != nil {
		t.Fatal(err)
	}
	if _, code, err := service.activateDevice(request); err == nil || code != "computer_offline" {
		t.Fatalf("offline activation unexpectedly succeeded: %s %v", code, err)
	}
	record, _ := service.loadDeviceRecord(paired.CertificateFingerprint)
	if record.Status != "pending" {
		t.Fatalf("offline activation changed status: %s", record.Status)
	}
	nodeAvailable = true
	if _, code, err := service.activateDevice(request); err != nil || code != "" {
		t.Fatalf("activation failed: %s %v", code, err)
	}
	invites, _ := os.ReadDir(service.invitesDir)
	if len(invites) != 0 {
		t.Fatal("completed invitation transaction was not removed")
	}
	record, _ = service.loadDeviceRecord(paired.CertificateFingerprint)
	if record.Status != "approved" || record.ActivatedAt == "" || record.PendingExpiresAt != "" {
		t.Fatalf("activation was not committed: %+v", record)
	}
	if _, code, err := service.activateDevice(request); err != nil || code != "" {
		t.Fatalf("repeat activation is not idempotent: %s %v", code, err)
	}
}

func TestDeviceRecordStateCombinationsAreStrict(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	base := deviceRecord{
		Schema: recordSchema, DeviceName: "Phone", CertificateFingerprint: strings.Repeat("cd", 32), CreatedAt: isoUTC(now), CertificateExpiresAt: isoUTC(now.Add(825 * 24 * time.Hour)),
	}
	valid := []deviceRecord{
		func() deviceRecord {
			value := base
			value.Status = "pending"
			value.PendingExpiresAt = isoUTC(now.Add(time.Minute))
			return value
		}(),
		func() deviceRecord {
			value := base
			value.Status = "approved"
			value.ApprovalRequestedAt = isoUTC(now)
			value.ApprovedAt = isoUTC(now)
			value.ActivatedAt = isoUTC(now)
			return value
		}(),
		func() deviceRecord {
			value := base
			value.Status = "revoked"
			value.ApprovalRequestedAt = isoUTC(now)
			value.ApprovedAt = isoUTC(now)
			value.ActivatedAt = isoUTC(now)
			value.RevokedAt = isoUTC(now)
			return value
		}(),
	}
	for _, record := range valid {
		if err := validateDeviceRecord(record); err != nil {
			t.Fatalf("valid %s record rejected: %v", record.Status, err)
		}
	}
	invalid := append([]deviceRecord(nil), valid...)
	invalid[0].ActivatedAt = isoUTC(now)
	invalid[1].PendingExpiresAt = isoUTC(now.Add(time.Minute))
	invalid[2].ActivatedAt = ""
	for _, record := range invalid {
		if err := validateDeviceRecord(record); err == nil {
			t.Fatalf("invalid %s field combination accepted: %+v", record.Status, record)
		}
	}
	missingExpiration := valid[1]
	missingExpiration.CertificateExpiresAt = ""
	if err := validateDeviceRecord(missingExpiration); err == nil {
		t.Fatal("device without certificate expiration was accepted")
	}
	invalidPendingOrder := valid[0]
	invalidPendingOrder.CertificateExpiresAt = isoUTC(now.Add(30 * time.Second))
	if err := validateDeviceRecord(invalidPendingOrder); err == nil {
		t.Fatal("pending authorization outliving its certificate was accepted")
	}
	replacementRevocation := valid[2]
	replacementRevocation.ReplacedByFingerprint = strings.Repeat("ef", 32)
	if err := validateDeviceRecord(replacementRevocation); err != nil {
		t.Fatalf("replacement revocation rejected: %v", err)
	}
	invalidReplacement := valid[0]
	invalidReplacement.ReplacedByFingerprint = strings.Repeat("ef", 32)
	if err := validateDeviceRecord(invalidReplacement); err == nil {
		t.Fatal("pending device accepted replacement revocation metadata")
	}
	replacementRevocation.ReplacedByFingerprint = replacementRevocation.CertificateFingerprint
	if err := validateDeviceRecord(replacementRevocation); err == nil {
		t.Fatal("device accepted itself as replacement")
	}
}

func TestInvitationListCancelAndOrphanRecovery(t *testing.T) {
	service := setupPublicTest(t)
	invitation := createInvitation(t, service)
	hash := invitationHash(invitation)
	var listed bytes.Buffer
	if err := service.invitationList(&listed); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(listed.String(), hash) || strings.Contains(listed.String(), "credential_pkcs12") {
		t.Fatalf("invitation list leaked secrets or omitted hash: %s", listed.String())
	}
	paired := pairRequest(t, service, invitation, `{"device_name":"Cancel Phone","credential_password":"credential-password-123"}`)
	if paired.Code != http.StatusOK {
		t.Fatalf("pair before cancel failed: %d %s", paired.Code, paired.Body.String())
	}
	var pairResult pairResponse
	if err := json.Unmarshal(paired.Body.Bytes(), &pairResult); err != nil {
		t.Fatal(err)
	}
	var cancelled bytes.Buffer
	if err := service.invitationCancel(hash, &cancelled); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(service.deviceRecordPath(pairResult.CertificateFingerprint)); !os.IsNotExist(err) {
		t.Fatal("cancelling a paired-pending invitation left its authorization record")
	}
	orphan := deviceRecord{
		Schema: recordSchema, DeviceName: "Orphan", CertificateFingerprint: strings.Repeat("ef", 32), Status: "pending",
		CreatedAt: isoUTC(time.Now()), CertificateExpiresAt: isoUTC(time.Now().Add(825 * 24 * time.Hour)), PendingExpiresAt: isoUTC(time.Now().Add(time.Hour)),
	}
	if err := service.writeDeviceRecord(orphan); err != nil {
		t.Fatal(err)
	}
	if err := service.cleanupExpiredState(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(service.deviceRecordPath(orphan.CertificateFingerprint)); !os.IsNotExist(err) {
		t.Fatal("unreferenced pending device survived recovery cleanup")
	}
}

func TestInvitationTimestampOrderIsStrict(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	record := invitationRecord{
		Schema: recordSchema, TokenHash: strings.Repeat("ab", 32),
		CreatedAt: isoUTC(now), ExpiresAt: isoUTC(now.Add(time.Minute)),
	}
	if err := validateInvitation(record); err != nil {
		t.Fatalf("valid invitation rejected: %v", err)
	}
	invalidExpiration := record
	invalidExpiration.ExpiresAt = isoUTC(now.Add(-time.Second))
	if err := validateInvitation(invalidExpiration); err == nil {
		t.Fatal("invitation expiring before creation was accepted")
	}
	invalidUse := record
	invalidUse.UsedAt = isoUTC(now.Add(-time.Second))
	invalidUse.DeviceName = "Phone"
	invalidUse.CredentialPasswordHash = strings.Repeat("cd", 32)
	invalidUse.CertificateFingerprint = strings.Repeat("ef", 32)
	invalidUse.CredentialPKCS12 = "encrypted"
	if err := validateInvitation(invalidUse); err == nil {
		t.Fatal("invitation used before creation was accepted")
	}
}

func TestDeviceRenewalApprovesReplacementAndRevokesOldCredential(t *testing.T) {
	service := setupPublicTest(t)
	token := strings.Repeat("01", 32)
	node := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer "+token {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = io.WriteString(writer, `{"ok":true,"computer_connected":true,"code":"ready","apps":[]}`)
	}))
	defer node.Close()
	service.node, _ = gatewaycore.New(node.URL, token)

	oldCredential := pairFixture(t, service)
	activateApproved(t, service, oldCredential.CertificateFingerprint)
	var renewal bytes.Buffer
	if err := service.issueRenewalInvitation(10*time.Minute, "Test PC", "", oldCredential.CertificateFingerprint, &renewal); err != nil {
		t.Fatal(err)
	}
	var invitation invitationResult
	if err := json.Unmarshal(renewal.Bytes(), &invitation); err != nil {
		t.Fatal(err)
	}
	paired := pairRequest(t, service, invitation.Invitation, `{"device_name":"Replacement Phone","credential_password":"credential-password-456"}`)
	if paired.Code != http.StatusOK {
		t.Fatalf("renewal pairing failed: %d %s", paired.Code, paired.Body.String())
	}
	var replacement pairResponse
	if err := json.Unmarshal(paired.Body.Bytes(), &replacement); err != nil {
		t.Fatal(err)
	}
	activateApproved(t, service, replacement.CertificateFingerprint)
	oldRecord, oldErr := service.loadDeviceRecord(oldCredential.CertificateFingerprint)
	newRecord, newErr := service.loadDeviceRecord(replacement.CertificateFingerprint)
	if oldErr != nil || newErr != nil || oldRecord.Status != "revoked" || newRecord.Status != "approved" {
		t.Fatalf("renewal state mismatch: old=%+v (%v) new=%+v (%v)", oldRecord, oldErr, newRecord, newErr)
	}
	if oldRecord.ReplacedByFingerprint != replacement.CertificateFingerprint {
		t.Fatal("renewal revocation is not tied to the replacement fingerprint")
	}

	var retryRenewal bytes.Buffer
	if err := service.issueRenewalInvitation(10*time.Minute, "Test PC", "", replacement.CertificateFingerprint, &retryRenewal); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(retryRenewal.Bytes(), &invitation); err != nil {
		t.Fatal(err)
	}
	retryPaired := pairRequest(t, service, invitation.Invitation, `{"device_name":"Crash Recovery Phone","credential_password":"credential-password-789"}`)
	var recovered pairResponse
	if retryPaired.Code != http.StatusOK || json.Unmarshal(retryPaired.Body.Bytes(), &recovered) != nil {
		t.Fatalf("recovery renewal pairing failed: %d %s", retryPaired.Code, retryPaired.Body.String())
	}
	newRecord.Status = "revoked"
	newRecord.RevokedAt = isoUTC(time.Now())
	newRecord.ReplacedByFingerprint = recovered.CertificateFingerprint
	if err := service.writeDeviceRecord(newRecord); err != nil {
		t.Fatal(err)
	}
	activateApproved(t, service, recovered.CertificateFingerprint)
	recoveredRecord, err := service.loadDeviceRecord(recovered.CertificateFingerprint)
	if err != nil || recoveredRecord.Status != "approved" {
		t.Fatalf("recovered replacement was not approved: %+v %v", recoveredRecord, err)
	}

	var cancelledRenewal bytes.Buffer
	if err := service.issueRenewalInvitation(10*time.Minute, "Test PC", "", recovered.CertificateFingerprint, &cancelledRenewal); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(cancelledRenewal.Bytes(), &invitation); err != nil {
		t.Fatal(err)
	}
	cancelledPair := pairRequest(t, service, invitation.Invitation, `{"device_name":"Cancelled Recovery Phone","credential_password":"credential-password-abc"}`)
	var cancelledReplacement pairResponse
	if cancelledPair.Code != http.StatusOK || json.Unmarshal(cancelledPair.Body.Bytes(), &cancelledReplacement) != nil {
		t.Fatalf("cancel recovery pairing failed: %d %s", cancelledPair.Code, cancelledPair.Body.String())
	}
	recoveredRecord.Status = "revoked"
	recoveredRecord.RevokedAt = isoUTC(time.Now())
	recoveredRecord.ReplacedByFingerprint = cancelledReplacement.CertificateFingerprint
	if err := service.writeDeviceRecord(recoveredRecord); err != nil {
		t.Fatal(err)
	}
	if err := service.invitationCancel(invitationHash(invitation.Invitation), io.Discard); err != nil {
		t.Fatalf("cancel did not roll back a partial renewal: %v", err)
	}
	restored, restoredErr := service.loadDeviceRecord(recovered.CertificateFingerprint)
	_, pendingErr := service.loadDeviceRecord(cancelledReplacement.CertificateFingerprint)
	if restoredErr != nil || restored.Status != "approved" || !os.IsNotExist(pendingErr) {
		t.Fatalf("cancelled renewal was not rolled back: old=%+v (%v) pending=%v", restored, restoredErr, pendingErr)
	}
}

func TestExpiredPendingDeviceIsCleaned(t *testing.T) {
	service := setupPublicTest(t)
	record := deviceRecord{
		Schema: recordSchema, DeviceName: "Expired", CertificateFingerprint: strings.Repeat("ab", 32),
		Status: "pending", CreatedAt: isoUTC(time.Now().Add(-time.Hour)), CertificateExpiresAt: isoUTC(time.Now().Add(824 * 24 * time.Hour)), PendingExpiresAt: isoUTC(time.Now().Add(-time.Minute)),
	}
	if err := service.writeDeviceRecord(record); err != nil {
		t.Fatal(err)
	}
	// Reading the store is not what cleans it: a device that never finished
	// pairing is removed by the sweep, which is what a gateway runs when it opens.
	if records, err := service.loadDeviceRecords(); err != nil || len(records) != 1 {
		t.Fatalf("reading the store changed it: %+v %v", records, err)
	}
	if err := service.cleanupExpiredState(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(service.deviceRecordPath(record.CertificateFingerprint)); !os.IsNotExist(err) {
		t.Fatal("expired pending device was not removed")
	}
}

func TestExpiredPartialRenewalRestoresOldCredential(t *testing.T) {
	service := setupPublicTest(t)
	now := time.Now().UTC().Truncate(time.Second)
	oldFingerprint := strings.Repeat("12", 32)
	newFingerprint := strings.Repeat("34", 32)
	old := deviceRecord{
		Schema: recordSchema, DeviceName: "Old Phone", CertificateFingerprint: oldFingerprint,
		Status: "revoked", CreatedAt: isoUTC(now.Add(-2 * time.Hour)), CertificateExpiresAt: isoUTC(now.Add(824 * 24 * time.Hour)), ActivatedAt: isoUTC(now.Add(-time.Hour)),
		ApprovalRequestedAt: isoUTC(now.Add(-time.Hour)), ApprovedAt: isoUTC(now.Add(-time.Hour)),
		RevokedAt: isoUTC(now.Add(-90 * time.Second)), ReplacedByFingerprint: newFingerprint,
	}
	pending := deviceRecord{
		Schema: recordSchema, DeviceName: "New Phone", CertificateFingerprint: newFingerprint,
		Status: "pending", CreatedAt: isoUTC(now.Add(-2 * time.Minute)), CertificateExpiresAt: isoUTC(now.Add(825 * 24 * time.Hour)), PendingExpiresAt: isoUTC(now.Add(-time.Minute)),
	}
	if err := service.writeDeviceRecord(old); err != nil {
		t.Fatal(err)
	}
	if err := service.writeDeviceRecord(pending); err != nil {
		t.Fatal(err)
	}
	token := strings.Repeat("A", 43)
	invitation := invitationRecord{
		Schema: recordSchema, TokenHash: invitationHash(token), CreatedAt: isoUTC(now.Add(-3 * time.Minute)), ExpiresAt: isoUTC(now.Add(-time.Minute)),
		UsedAt: isoUTC(now.Add(-2 * time.Minute)), DeviceName: pending.DeviceName, CredentialPasswordHash: strings.Repeat("56", 32),
		CertificateFingerprint: newFingerprint, CredentialPKCS12: "encrypted", ReplacesFingerprint: oldFingerprint,
	}
	if err := service.writeInvitation(invitation); err != nil {
		t.Fatal(err)
	}
	if err := service.cleanupExpiredState(); err != nil {
		t.Fatal(err)
	}
	restored, err := service.loadDeviceRecord(oldFingerprint)
	if err != nil || restored.Status != "approved" || restored.RevokedAt != "" || restored.ReplacedByFingerprint != "" {
		t.Fatalf("expired renewal did not restore old credential: %+v %v", restored, err)
	}
	if _, err := service.loadDeviceRecord(newFingerprint); !os.IsNotExist(err) {
		t.Fatalf("expired pending replacement remains: %v", err)
	}
	if _, err := os.Stat(service.invitationPath(invitation.TokenHash)); !os.IsNotExist(err) {
		t.Fatalf("expired renewal invitation remains: %v", err)
	}
}

func TestExplicitRevokeOverridesPartialRenewalRollback(t *testing.T) {
	service := setupPublicTest(t)
	now := time.Now().UTC().Truncate(time.Second)
	fingerprint := strings.Repeat("78", 32)
	record := deviceRecord{
		Schema: recordSchema, DeviceName: "Phone", CertificateFingerprint: fingerprint,
		Status: "revoked", CreatedAt: isoUTC(now.Add(-2 * time.Hour)), CertificateExpiresAt: isoUTC(now.Add(824 * 24 * time.Hour)), ActivatedAt: isoUTC(now.Add(-time.Hour)),
		ApprovalRequestedAt: isoUTC(now.Add(-time.Hour)), ApprovedAt: isoUTC(now.Add(-time.Hour)),
		RevokedAt: isoUTC(now), ReplacedByFingerprint: strings.Repeat("9a", 32),
	}
	if err := service.writeDeviceRecord(record); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := service.deviceRevoke(fingerprint, &output); err != nil {
		t.Fatal(err)
	}
	current, err := service.loadDeviceRecord(fingerprint)
	if err != nil || current.Status != "revoked" || current.ReplacedByFingerprint != "" || !strings.Contains(output.String(), `"changed":true`) {
		t.Fatalf("explicit revoke did not replace renewal rollback intent: %+v %v %s", current, err, output.String())
	}
}

func TestPairRateLimitBlocksExcessRequests(t *testing.T) {
	service := setupPublicTest(t)
	for i := 0; i < pairRateMaxPerIP; i++ {
		request := httptest.NewRequest(http.MethodPost, pairRequestPath, strings.NewReader(`{}`))
		request.Header.Set("Authorization", "Invitation "+strings.Repeat("z", 43))
		recorder := httptest.NewRecorder()
		service.pairHTTPHandler(recorder, request)
		if recorder.Code == http.StatusTooManyRequests {
			t.Fatalf("rate limiter engaged too early at request %d", i+1)
		}
	}
	request := httptest.NewRequest(http.MethodPost, pairRequestPath, strings.NewReader(`{}`))
	request.Header.Set("Authorization", "Invitation "+strings.Repeat("z", 43))
	recorder := httptest.NewRecorder()
	service.pairHTTPHandler(recorder, request)
	if recorder.Code != http.StatusTooManyRequests {
		t.Fatalf("rate limiter failed to block excess request: %d", recorder.Code)
	}
}
