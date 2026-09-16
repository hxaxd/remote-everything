package devicecore

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	setupcodec "github.com/hxaxd/remote-everything/internal/setup"
)

type invitationRecord struct {
	Schema                 int    `json:"schema"`
	TokenHash              string `json:"token_hash"`
	CreatedAt              string `json:"created_at"`
	ExpiresAt              string `json:"expires_at"`
	UsedAt                 string `json:"used_at,omitempty"`
	DeviceName             string `json:"device_name,omitempty"`
	CredentialPasswordHash string `json:"credential_password_hash,omitempty"`
	CertificateFingerprint string `json:"certificate_fingerprint,omitempty"`
	CredentialPKCS12       string `json:"credential_pkcs12,omitempty"`
	ReplacesFingerprint    string `json:"replaces_fingerprint,omitempty"`
}

type invitationResult struct {
	OK             bool   `json:"ok"`
	InstallationID string `json:"installation_id"`
	Invitation     string `json:"invitation"`
	ExpiresAt      string `json:"expires_at"`
	SetupURI       string `json:"setup_uri"`
	QRFile         string `json:"qr_file,omitempty"`
}

type invitationListRecord struct {
	TokenHash              string `json:"token_hash"`
	CreatedAt              string `json:"created_at"`
	ExpiresAt              string `json:"expires_at"`
	Status                 string `json:"status"`
	DeviceName             string `json:"device_name,omitempty"`
	CertificateFingerprint string `json:"certificate_fingerprint,omitempty"`
}

func (service *Trust) invitationPath(hash string) string {
	return filepath.Join(service.invitesDir, hash+".json")
}

func invitationHash(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}

func validateInvitation(record invitationRecord) error {
	if record.Schema != recordSchema || !validHex64.MatchString(record.TokenHash) {
		return errors.New("invalid invitation record")
	}
	created, err := parseTimestamp(record.CreatedAt)
	if err != nil {
		return errors.New("invalid invitation created_at")
	}
	expires, err := parseTimestamp(record.ExpiresAt)
	if err != nil || !expires.After(created) {
		return errors.New("invalid invitation expires_at")
	}
	if record.ReplacesFingerprint != "" && !validHex64.MatchString(record.ReplacesFingerprint) {
		return errors.New("invalid replacement fingerprint")
	}
	if record.UsedAt != "" {
		used, err := parseTimestamp(record.UsedAt)
		if err != nil || used.Before(created) || used.After(expires) {
			return errors.New("invalid invitation used_at")
		}
		if !validDeviceName(record.DeviceName) || !validHex64.MatchString(record.CredentialPasswordHash) || !validHex64.MatchString(record.CertificateFingerprint) || record.CredentialPKCS12 == "" {
			return errors.New("invalid used invitation transaction")
		}
	} else if record.DeviceName != "" || record.CredentialPasswordHash != "" || record.CertificateFingerprint != "" || record.CredentialPKCS12 != "" {
		return errors.New("unused invitation contains transaction state")
	}
	return nil
}

func (service *Trust) loadInvitation(token string) (invitationRecord, error) {
	hash := invitationHash(token)
	var record invitationRecord
	if err := jsonfile.Read(service.invitationPath(hash), &record); err != nil {
		return invitationRecord{}, err
	}
	if err := validateInvitation(record); err != nil || record.TokenHash != hash {
		return invitationRecord{}, errors.New("invalid invitation record")
	}
	expires, _ := parseTimestamp(record.ExpiresAt)
	if !time.Now().UTC().Before(expires) {
		return invitationRecord{}, errors.New("invitation unavailable")
	}
	return record, nil
}

func (service *Trust) writeInvitation(record invitationRecord) error {
	if err := validateInvitation(record); err != nil {
		return err
	}
	contents, err := json.Marshal(record)
	if err != nil {
		return err
	}
	path := service.invitationPath(record.TokenHash)
	if err := atomicfile.Write(path, append(contents, '\n'), 0o600); err != nil {
		return err
	}
	return atomicfile.MatchDirectoryOwner(path)
}

func (service *Trust) issueInvitation(ttl time.Duration, name, origin, qrFile string, output io.Writer) error {
	return service.issueInvitationReplacing(ttl, name, origin, qrFile, "", output)
}

func (service *Trust) issueInvitationReplacing(ttl time.Duration, name, origin, qrFile, replaces string, output io.Writer) error {
	if err := service.cleanupExpiredState(); err != nil {
		return err
	}
	if ttl < time.Minute || ttl > 24*time.Hour {
		return errors.New("invite ttl must be between 1m and 24h")
	}
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return err
	}
	token := base64.RawURLEncoding.EncodeToString(tokenBytes)
	now := time.Now().UTC()
	record := invitationRecord{
		Schema: recordSchema, TokenHash: invitationHash(token),
		CreatedAt: isoUTC(now), ExpiresAt: isoUTC(now.Add(ttl)), ReplacesFingerprint: replaces,
	}
	setupURI, err := setupcodec.Build("public", service.installationID, name, origin, token, "", "")
	if err != nil {
		return err
	}
	if err := service.writeInvitation(record); err != nil {
		return err
	}
	if err := setupcodec.WriteQR(qrFile, setupURI); err != nil {
		_ = os.Remove(service.invitationPath(record.TokenHash))
		return err
	}
	service.audit("device invitation issued", "expires_at", record.ExpiresAt)
	return json.NewEncoder(output).Encode(invitationResult{
		OK: true, InstallationID: service.installationID, Invitation: token, ExpiresAt: record.ExpiresAt, SetupURI: setupURI, QRFile: qrFile,
	})
}

func (service *Trust) issueRenewalInvitation(ttl time.Duration, name, origin, qrFile, fingerprint string, output io.Writer) error {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || record.Status != "approved" {
		return errors.New("approved device not found")
	}
	return service.issueInvitationReplacing(ttl, name, origin, qrFile, fingerprint, output)
}

func (service *Trust) restoreReplacedDevice(record invitationRecord) error {
	if record.ReplacesFingerprint == "" || record.CertificateFingerprint == "" {
		return nil
	}
	replaced, err := service.loadDeviceRecord(record.ReplacesFingerprint)
	if err != nil {
		return err
	}
	if replaced.Status != "revoked" || replaced.ReplacedByFingerprint != record.CertificateFingerprint {
		return nil
	}
	replacement, err := service.loadDeviceRecord(record.CertificateFingerprint)
	if err == nil && replacement.Status == "approved" && replacement.ActivatedAt != "" {
		return nil
	}
	replaced.Status = "approved"
	replaced.RevokedAt = ""
	replaced.ReplacedByFingerprint = ""
	return service.writeDeviceRecord(replaced)
}

func (service *Trust) cleanupExpiredState() error {
	now := time.Now().UTC()
	referencedPending := map[string]bool{}
	entries, err := os.ReadDir(service.invitesDir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(service.invitesDir, entry.Name())
		var record invitationRecord
		if err := jsonfile.Read(path, &record); err != nil || validateInvitation(record) != nil {
			service.audit("corrupt invitation skipped", "path", entry.Name())
			continue
		}
		expires, _ := parseTimestamp(record.ExpiresAt)
		if !now.Before(expires) {
			if err := service.restoreReplacedDevice(record); err != nil {
				return err
			}
			if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			continue
		}
		if record.UsedAt != "" {
			referencedPending[record.CertificateFingerprint] = true
		}
	}
	records, err := service.loadDeviceRecords()
	if err != nil {
		return err
	}
	for _, record := range records {
		if record.Status == "pending" && !referencedPending[record.CertificateFingerprint] {
			if err := os.Remove(service.deviceRecordPath(record.CertificateFingerprint)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
			service.audit("orphan pending device removed", "fingerprint", record.CertificateFingerprint)
		}
	}
	return nil
}

func (service *Trust) invitationList(output io.Writer) error {
	if err := service.cleanupExpiredState(); err != nil {
		return err
	}
	entries, err := os.ReadDir(service.invitesDir)
	if err != nil {
		return err
	}
	result := make([]invitationListRecord, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(service.invitesDir, entry.Name())
		var record invitationRecord
		if err := jsonfile.Read(path, &record); err != nil || validateInvitation(record) != nil {
			service.audit("corrupt invitation skipped", "path", entry.Name())
			continue
		}
		status := "available"
		if record.UsedAt != "" {
			status = "paired_pending"
		}
		result = append(result, invitationListRecord{
			TokenHash: record.TokenHash, CreatedAt: record.CreatedAt, ExpiresAt: record.ExpiresAt, Status: status,
			DeviceName: record.DeviceName, CertificateFingerprint: record.CertificateFingerprint,
		})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt < result[j].CreatedAt })
	return json.NewEncoder(output).Encode(result)
}

func (service *Trust) invitationCancel(hash string, output io.Writer) error {
	hash = strings.ToLower(strings.TrimSpace(hash))
	if !validHex64.MatchString(hash) {
		return errors.New("invalid invitation hash")
	}
	path := service.invitationPath(hash)
	var record invitationRecord
	if err := jsonfile.Read(path, &record); err != nil || validateInvitation(record) != nil || record.TokenHash != hash {
		return errors.New("invitation not found")
	}
	if record.CertificateFingerprint != "" {
		device, err := service.loadDeviceRecord(record.CertificateFingerprint)
		if err == nil {
			if device.Status != "pending" {
				return errors.New("activated invitation cannot be cancelled")
			}
			if err := service.restoreReplacedDevice(record); err != nil {
				return err
			}
			if err := os.Remove(service.deviceRecordPath(device.CertificateFingerprint)); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if err := os.Remove(path); err != nil {
		return err
	}
	service.audit("device invitation cancelled", "token_hash", hash)
	return json.NewEncoder(output).Encode(map[string]any{"ok": true, "token_hash": hash})
}

func (service *Trust) invitationTransaction(fingerprint string) (invitationRecord, string, error) {
	entries, err := os.ReadDir(service.invitesDir)
	if err != nil {
		return invitationRecord{}, "", err
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(service.invitesDir, entry.Name())
		var record invitationRecord
		if err := jsonfile.Read(path, &record); err != nil || validateInvitation(record) != nil {
			return invitationRecord{}, "", errors.New("invalid invitation state")
		}
		if record.CertificateFingerprint == fingerprint {
			return record, path, nil
		}
	}
	return invitationRecord{}, "", os.ErrNotExist
}
