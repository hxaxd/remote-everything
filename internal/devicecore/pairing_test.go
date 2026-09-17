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

	"software.sslmate.com/src/go-pkcs12"
)

func TestInvitationPairingIsSingleUseAndPending(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	service := fixture.trust
	if recorder := pairInvitation(t, service, "bad", `{}`); recorder.Code != http.StatusUnauthorized {
		t.Fatalf("invalid invitation status = %d", recorder.Code)
	}
	invitation := fixture.invite(t, 0)
	body := `{"device_name":"Test Phone","credential_password":"credential-password-123"}`
	first := pairInvitation(t, service, invitation, body)
	if first.Code != http.StatusOK {
		t.Fatalf("pairing failed: %d %s", first.Code, first.Body.String())
	}
	second := pairInvitation(t, service, invitation, body)
	if second.Code != http.StatusOK || second.Body.String() != first.Body.String() {
		t.Fatalf("idempotent pairing replay changed response: %d %s", second.Code, second.Body.String())
	}
	if changed := pairInvitation(t, service, invitation, `{"device_name":"Other Phone","credential_password":"credential-password-456"}`); changed.Code != http.StatusUnauthorized {
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
	// Redeeming an invitation is what puts the node it was issued for on the
	// device: the client never asks for one.
	if len(record.Nodes) != 1 || record.Nodes[0] != testNodeIDs[0] {
		t.Fatalf("the invitation did not decide what the device holds: %+v", record.Nodes)
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
	fixture := newGatewayFixture(t, false)
	paired := fixture.pair(t, 0)
	fingerprint := paired.CertificateFingerprint
	if code, err := fixture.activate(fingerprint, 0); err == nil || code != "approval_pending" {
		t.Fatalf("unapproved activation unexpectedly succeeded: %s %v", code, err)
	}
	if err := fixture.trust.deviceApprove(fingerprint, io.Discard); err != nil {
		t.Fatal(err)
	}
	fixture.nodes[0].setDown(true)
	if code, err := fixture.activate(fingerprint, 0); err == nil || code != "computer_offline" {
		t.Fatalf("offline activation unexpectedly succeeded: %s %v", code, err)
	}
	record, _ := fixture.trust.loadDeviceRecord(fingerprint)
	if record.Status != "pending" {
		t.Fatalf("offline activation changed status: %s", record.Status)
	}
	fixture.nodes[0].setDown(false)
	if code, err := fixture.activate(fingerprint, 0); err != nil || code != "" {
		t.Fatalf("activation failed: %s %v", code, err)
	}
	invites, _ := os.ReadDir(fixture.trust.invitesDir)
	if len(invites) != 0 {
		t.Fatal("completed invitation transaction was not removed")
	}
	record, _ = fixture.trust.loadDeviceRecord(fingerprint)
	if record.Status != "approved" || record.ActivatedAt == "" || record.PendingExpiresAt != "" {
		t.Fatalf("activation was not committed: %+v", record)
	}
	if code, err := fixture.activate(fingerprint, 0); err != nil || code != "" {
		t.Fatalf("repeat activation is not idempotent: %s %v", code, err)
	}
}

func TestDeviceRecordStateCombinationsAreStrict(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	base := deviceRecord{
		Schema: recordSchema, DeviceName: "Phone", CertificateFingerprint: strings.Repeat("cd", 32), Nodes: []string{testNodeIDs[0]},
		CreatedAt: isoUTC(now), CertificateExpiresAt: isoUTC(now.Add(825 * 24 * time.Hour)),
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
	// A device says which nodes it holds even when that is none: a record that
	// does not is one whose permissions were not written down.
	unnamed := valid[1]
	unnamed.Nodes = nil
	if err := validateDeviceRecord(unnamed); err == nil {
		t.Fatal("device without a node list was accepted")
	}
	repeated := valid[1]
	repeated.Nodes = []string{testNodeIDs[0], testNodeIDs[0]}
	if err := validateDeviceRecord(repeated); err == nil {
		t.Fatal("device holding one node twice was accepted")
	}
	malformed := valid[1]
	malformed.Nodes = []string{"Desk"}
	if err := validateDeviceRecord(malformed); err == nil {
		t.Fatal("device holding a node that is not an id was accepted")
	}
	// And a device that holds no node at all is coherent: an operator can take
	// every node away from it without revoking the credential it keeps.
	none := valid[1]
	none.Nodes = []string{}
	if err := validateDeviceRecord(none); err != nil {
		t.Fatalf("a device holding no node was rejected: %v", err)
	}
}

func TestInvitationListCancelAndOrphanRecovery(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	service := fixture.trust
	invitation := fixture.invite(t, 0)
	hash := invitationHash(invitation)
	var listed bytes.Buffer
	if err := service.invitationList(&listed); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(listed.String(), hash) || !strings.Contains(listed.String(), testNodeIDs[0]) || strings.Contains(listed.String(), "credential_pkcs12") {
		t.Fatalf("invitation list leaked secrets, omitted its hash, or hid the node it is for: %s", listed.String())
	}
	paired := pairInvitation(t, service, invitation, `{"device_name":"Cancel Phone","credential_password":"credential-password-123"}`)
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
		Schema: recordSchema, DeviceName: "Orphan", CertificateFingerprint: strings.Repeat("ef", 32), Nodes: []string{testNodeIDs[0]},
		Status: "pending", CreatedAt: isoUTC(time.Now()), CertificateExpiresAt: isoUTC(time.Now().Add(825 * 24 * time.Hour)), PendingExpiresAt: isoUTC(time.Now().Add(time.Hour)),
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
		Schema: recordSchema, TokenHash: strings.Repeat("ab", 32), NodeID: testNodeIDs[0],
		CreatedAt: isoUTC(now), ExpiresAt: isoUTC(now.Add(time.Minute)),
	}
	if err := validateInvitation(record); err != nil {
		t.Fatalf("valid invitation rejected: %v", err)
	}
	// An invitation is for one node, and that node is named by its id: one that
	// names none, or names something that is not an id, opens nothing.
	for name, broken := range map[string]invitationRecord{
		"no node":      func() invitationRecord { value := record; value.NodeID = ""; return value }(),
		"short node":   func() invitationRecord { value := record; value.NodeID = "Desk"; return value }(),
		"invalid node": func() invitationRecord { value := record; value.NodeID = strings.Repeat("z", 64); return value }(),
	} {
		if err := validateInvitation(broken); err == nil {
			t.Fatalf("an invitation with %s was accepted", name)
		}
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
	fixture := newGatewayFixture(t, false)
	service := fixture.trust
	renew := func(t *testing.T, fingerprint string) string {
		t.Helper()
		var renewal bytes.Buffer
		if err := service.issueRenewalInvitation(10*time.Minute, fixture.nodeAt(0), "Test PC", "", fingerprint, &renewal); err != nil {
			t.Fatal(err)
		}
		var invitation invitationResult
		if err := json.Unmarshal(renewal.Bytes(), &invitation); err != nil {
			t.Fatal(err)
		}
		return invitation.Invitation
	}

	oldCredential := fixture.pair(t, 0)
	fixture.admit(t, oldCredential.CertificateFingerprint, 0)
	paired := pairInvitation(t, service, renew(t, oldCredential.CertificateFingerprint), `{"device_name":"Replacement Phone","credential_password":"credential-password-456"}`)
	if paired.Code != http.StatusOK {
		t.Fatalf("renewal pairing failed: %d %s", paired.Code, paired.Body.String())
	}
	var replacement pairResponse
	if err := json.Unmarshal(paired.Body.Bytes(), &replacement); err != nil {
		t.Fatal(err)
	}
	fixture.admit(t, replacement.CertificateFingerprint, 0)
	oldRecord, oldErr := service.loadDeviceRecord(oldCredential.CertificateFingerprint)
	newRecord, newErr := service.loadDeviceRecord(replacement.CertificateFingerprint)
	if oldErr != nil || newErr != nil || oldRecord.Status != "revoked" || newRecord.Status != "approved" {
		t.Fatalf("renewal state mismatch: old=%+v (%v) new=%+v (%v)", oldRecord, oldErr, newRecord, newErr)
	}
	if oldRecord.ReplacedByFingerprint != replacement.CertificateFingerprint {
		t.Fatal("renewal revocation is not tied to the replacement fingerprint")
	}
	// The replacement holds what the credential it replaced held: renewing is not
	// a change of what the device may reach.
	if strings.Join(newRecord.Nodes, ",") != strings.Join(oldRecord.Nodes, ",") {
		t.Fatalf("renewal changed what the device holds: %v -> %v", oldRecord.Nodes, newRecord.Nodes)
	}

	retryPaired := pairInvitation(t, service, renew(t, replacement.CertificateFingerprint), `{"device_name":"Crash Recovery Phone","credential_password":"credential-password-789"}`)
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
	fixture.admit(t, recovered.CertificateFingerprint, 0)
	recoveredRecord, err := service.loadDeviceRecord(recovered.CertificateFingerprint)
	if err != nil || recoveredRecord.Status != "approved" {
		t.Fatalf("recovered replacement was not approved: %+v %v", recoveredRecord, err)
	}

	cancelledInvitation := renew(t, recovered.CertificateFingerprint)
	cancelledPair := pairInvitation(t, service, cancelledInvitation, `{"device_name":"Cancelled Recovery Phone","credential_password":"credential-password-abc"}`)
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
	if err := service.invitationCancel(invitationHash(cancelledInvitation), io.Discard); err != nil {
		t.Fatalf("cancel did not roll back a partial renewal: %v", err)
	}
	restored, restoredErr := service.loadDeviceRecord(recovered.CertificateFingerprint)
	_, pendingErr := service.loadDeviceRecord(cancelledReplacement.CertificateFingerprint)
	if restoredErr != nil || restored.Status != "approved" || !os.IsNotExist(pendingErr) {
		t.Fatalf("cancelled renewal was not rolled back: old=%+v (%v) pending=%v", restored, restoredErr, pendingErr)
	}
}

// A renewal replaces a credential and nothing else, so the node it names is one
// the device already holds.
func TestRenewalIsRefusedForANodeTheDeviceDoesNotHold(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	paired := fixture.pair(t, 0)
	fixture.admit(t, paired.CertificateFingerprint, 0)
	if err := fixture.trust.issueRenewalInvitation(10*time.Minute, fixture.nodeAt(1), "Test PC", "", paired.CertificateFingerprint, io.Discard); err == nil {
		t.Fatal("a renewal was issued for a node the device does not hold")
	}
	if err := fixture.trust.issueRenewalInvitation(10*time.Minute, fixture.nodeAt(0), "Test PC", "", strings.Repeat("ef", 32), io.Discard); err == nil {
		t.Fatal("a renewal was issued for a device that is not approved")
	}
}

func TestExpiredPendingDeviceIsCleaned(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	record := deviceRecord{
		Schema: recordSchema, DeviceName: "Expired", CertificateFingerprint: strings.Repeat("ab", 32), Nodes: []string{testNodeIDs[0]},
		Status: "pending", CreatedAt: isoUTC(time.Now().Add(-time.Hour)), CertificateExpiresAt: isoUTC(time.Now().Add(824 * 24 * time.Hour)), PendingExpiresAt: isoUTC(time.Now().Add(-time.Minute)),
	}
	if err := fixture.trust.writeDeviceRecord(record); err != nil {
		t.Fatal(err)
	}
	// Reading the store is not what cleans it: a device that never finished
	// pairing is removed by the sweep, which is what a gateway runs when it opens.
	if records, err := fixture.trust.loadDeviceRecords(); err != nil || len(records) != 1 {
		t.Fatalf("reading the store changed it: %+v %v", records, err)
	}
	if err := fixture.trust.cleanupExpiredState(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture.trust.deviceRecordPath(record.CertificateFingerprint)); !os.IsNotExist(err) {
		t.Fatal("expired pending device was not removed")
	}
}

func TestExpiredPartialRenewalRestoresOldCredential(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	service := fixture.trust
	now := time.Now().UTC().Truncate(time.Second)
	oldFingerprint := strings.Repeat("12", 32)
	newFingerprint := strings.Repeat("34", 32)
	old := deviceRecord{
		Schema: recordSchema, DeviceName: "Old Phone", CertificateFingerprint: oldFingerprint, Nodes: []string{testNodeIDs[0]},
		Status: "revoked", CreatedAt: isoUTC(now.Add(-2 * time.Hour)), CertificateExpiresAt: isoUTC(now.Add(824 * 24 * time.Hour)), ActivatedAt: isoUTC(now.Add(-time.Hour)),
		ApprovalRequestedAt: isoUTC(now.Add(-time.Hour)), ApprovedAt: isoUTC(now.Add(-time.Hour)),
		RevokedAt: isoUTC(now.Add(-90 * time.Second)), ReplacedByFingerprint: newFingerprint,
	}
	pending := deviceRecord{
		Schema: recordSchema, DeviceName: "New Phone", CertificateFingerprint: newFingerprint, Nodes: []string{testNodeIDs[0]},
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
		Schema: recordSchema, TokenHash: invitationHash(token), NodeID: testNodeIDs[0],
		CreatedAt: isoUTC(now.Add(-3 * time.Minute)), ExpiresAt: isoUTC(now.Add(-time.Minute)),
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
	fixture := newGatewayFixture(t, false)
	service := fixture.trust
	now := time.Now().UTC().Truncate(time.Second)
	fingerprint := strings.Repeat("78", 32)
	record := deviceRecord{
		Schema: recordSchema, DeviceName: "Phone", CertificateFingerprint: fingerprint, Nodes: []string{testNodeIDs[0]},
		Status: "revoked", CreatedAt: isoUTC(now.Add(-2 * time.Hour)), CertificateExpiresAt: isoUTC(now.Add(824 * 24 * time.Hour)), ActivatedAt: isoUTC(now.Add(-time.Hour)),
		ApprovalRequestedAt: isoUTC(now.Add(-time.Hour)), ApprovedAt: isoUTC(now.Add(-time.Hour)),
		RevokedAt: isoUTC(now), ReplacedByFingerprint: strings.Repeat("9a", 32),
	}
	if err := service.writeDeviceRecord(record); err != nil {
		t.Fatal(err)
	}
	var output bytes.Buffer
	if err := service.deviceRevoke(fingerprint, "", &output); err != nil {
		t.Fatal(err)
	}
	current, err := service.loadDeviceRecord(fingerprint)
	if err != nil || current.Status != "revoked" || current.ReplacedByFingerprint != "" || !strings.Contains(output.String(), `"changed":true`) {
		t.Fatalf("explicit revoke did not replace renewal rollback intent: %+v %v %s", current, err, output.String())
	}
}

func TestPairRateLimitBlocksExcessRequests(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	service := fixture.trust
	excess := func() int {
		request := httptest.NewRequest(http.MethodPost, pairRequestPath, strings.NewReader(`{}`))
		request.Header.Set("Authorization", "Invitation "+strings.Repeat("z", 43))
		recorder := httptest.NewRecorder()
		service.pairHTTPHandler(recorder, request)
		return recorder.Code
	}
	for i := 0; i < pairRateMaxPerIP; i++ {
		if code := excess(); code == http.StatusTooManyRequests {
			t.Fatalf("rate limiter engaged too early at request %d", i+1)
		}
	}
	if code := excess(); code != http.StatusTooManyRequests {
		t.Fatalf("rate limiter failed to block excess request: %d", code)
	}
}
