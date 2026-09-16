package devicecore

import (
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
)

const recordSchema = 1

type deviceRecord struct {
	Schema                 int    `json:"schema"`
	DeviceName             string `json:"device_name"`
	CertificateFingerprint string `json:"certificate_fingerprint"`
	Status                 string `json:"status"`
	CreatedAt              string `json:"created_at"`
	CertificateExpiresAt   string `json:"certificate_expires_at"`
	PendingExpiresAt       string `json:"pending_expires_at,omitempty"`
	ApprovalRequestedAt    string `json:"approval_requested_at,omitempty"`
	ApprovedAt             string `json:"approved_at,omitempty"`
	ActivatedAt            string `json:"activated_at,omitempty"`
	RevokedAt              string `json:"revoked_at,omitempty"`
	ReplacedByFingerprint  string `json:"replaced_by_fingerprint,omitempty"`
}

func isoUTC(value time.Time) string {
	return value.UTC().Truncate(time.Second).Format(time.RFC3339)
}

func parseTimestamp(value string) (time.Time, error) {
	return time.Parse(time.RFC3339, value)
}

func (service *Trust) deviceRecordPath(fingerprint string) string {
	return filepath.Join(service.devicesDir, fingerprint+".json")
}

func validateDeviceRecord(record deviceRecord) error {
	if record.Schema != recordSchema || !validHex64.MatchString(record.CertificateFingerprint) || !validDeviceName(record.DeviceName) {
		return errors.New("invalid device record")
	}
	if record.Status != "pending" && record.Status != "approved" && record.Status != "revoked" {
		return errors.New("invalid device status")
	}
	created, err := parseTimestamp(record.CreatedAt)
	if err != nil {
		return errors.New("invalid device created_at")
	}
	certificateExpires, err := parseTimestamp(record.CertificateExpiresAt)
	if err != nil || !certificateExpires.After(created) {
		return errors.New("invalid certificate expiration")
	}
	switch record.Status {
	case "pending":
		expires, err := parseTimestamp(record.PendingExpiresAt)
		if err != nil || !expires.After(created) || expires.After(certificateExpires) || record.ActivatedAt != "" || record.RevokedAt != "" || record.ReplacedByFingerprint != "" {
			return errors.New("invalid pending expiration")
		}
		if record.ApprovalRequestedAt == "" {
			if record.ApprovedAt != "" {
				return errors.New("invalid pending approval state")
			}
		} else {
			requested, requestErr := parseTimestamp(record.ApprovalRequestedAt)
			if requestErr != nil || requested.Before(created) || requested.After(expires) {
				return errors.New("invalid approval request time")
			}
			if record.ApprovedAt != "" {
				approved, approveErr := parseTimestamp(record.ApprovedAt)
				if approveErr != nil || approved.Before(requested) || approved.After(expires) {
					return errors.New("invalid approval time")
				}
			}
		}
	case "approved":
		requested, requestErr := parseTimestamp(record.ApprovalRequestedAt)
		approved, approveErr := parseTimestamp(record.ApprovedAt)
		activated, err := parseTimestamp(record.ActivatedAt)
		if requestErr != nil || approveErr != nil || err != nil || requested.Before(created) || approved.Before(requested) || activated.Before(approved) || !activated.Before(certificateExpires) || record.PendingExpiresAt != "" || record.RevokedAt != "" || record.ReplacedByFingerprint != "" {
			return errors.New("invalid approved device state")
		}
	case "revoked":
		requested, requestErr := parseTimestamp(record.ApprovalRequestedAt)
		approved, approveErr := parseTimestamp(record.ApprovedAt)
		activated, activatedErr := parseTimestamp(record.ActivatedAt)
		revoked, revokedErr := parseTimestamp(record.RevokedAt)
		if requestErr != nil || approveErr != nil || activatedErr != nil || revokedErr != nil || requested.Before(created) || approved.Before(requested) || activated.Before(approved) || !activated.Before(certificateExpires) || revoked.Before(activated) || record.PendingExpiresAt != "" || (record.ReplacedByFingerprint != "" && (!validHex64.MatchString(record.ReplacedByFingerprint) || record.ReplacedByFingerprint == record.CertificateFingerprint)) {
			return errors.New("invalid revoked device state")
		}
	}
	return nil
}

func (service *Trust) loadDeviceRecord(fingerprint string) (deviceRecord, error) {
	if !validHex64.MatchString(fingerprint) {
		return deviceRecord{}, errors.New("invalid device fingerprint")
	}
	var record deviceRecord
	if err := jsonfile.Read(service.deviceRecordPath(fingerprint), &record); err != nil {
		return deviceRecord{}, err
	}
	if err := validateDeviceRecord(record); err != nil || record.CertificateFingerprint != fingerprint {
		return deviceRecord{}, errors.New("invalid device record")
	}
	return record, nil
}

func (service *Trust) writeDeviceRecord(record deviceRecord) error {
	if err := validateDeviceRecord(record); err != nil {
		return err
	}
	contents, err := json.Marshal(record)
	if err != nil {
		return err
	}
	path := service.deviceRecordPath(record.CertificateFingerprint)
	if err := atomicfile.Write(path, append(contents, '\n'), 0o600); err != nil {
		return err
	}
	return atomicfile.MatchDirectoryOwner(path)
}

func (service *Trust) loadDeviceRecords() ([]deviceRecord, error) {
	entries, err := os.ReadDir(service.devicesDir)
	if err != nil {
		return nil, err
	}
	records := make([]deviceRecord, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		fingerprint := strings.TrimSuffix(entry.Name(), ".json")
		record, err := service.loadDeviceRecord(fingerprint)
		if err != nil {
			service.audit("corrupt device record skipped", "fingerprint", fingerprint, "error", err.Error())
			continue
		}
		if record.Status == "pending" {
			expires, _ := parseTimestamp(record.PendingExpiresAt)
			if !time.Now().UTC().Before(expires) {
				_ = os.Remove(service.deviceRecordPath(fingerprint))
				continue
			}
		}
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool { return records[i].CreatedAt < records[j].CreatedAt })
	return records, nil
}

func (service *Trust) deviceList(output io.Writer) error {
	if err := service.cleanupExpiredState(); err != nil {
		return err
	}
	records, err := service.loadDeviceRecords()
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(records)
}

func (service *Trust) deviceRevoke(fingerprint string, output io.Writer) error {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || record.Status == "pending" {
		return errors.New("approved fingerprint not found")
	}
	changed := record.Status != "revoked" || record.ReplacedByFingerprint != ""
	if changed {
		if record.Status != "revoked" {
			record.Status = "revoked"
			record.RevokedAt = isoUTC(time.Now())
		}
		record.ReplacedByFingerprint = ""
		if err := service.writeDeviceRecord(record); err != nil {
			return err
		}
		service.audit("device revoked", "fingerprint", fingerprint)
	}
	return json.NewEncoder(output).Encode(map[string]any{"ok": true, "fingerprint": fingerprint, "changed": changed})
}

func (service *Trust) deviceApprove(fingerprint string, output io.Writer) error {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || (record.Status != "pending" && record.Status != "approved") || record.ApprovalRequestedAt == "" {
		return errors.New("pending approval fingerprint not found")
	}
	if record.Status == "approved" {
		return json.NewEncoder(output).Encode(map[string]any{"ok": true, "fingerprint": fingerprint, "changed": false})
	}
	expires, _ := parseTimestamp(record.PendingExpiresAt)
	if !time.Now().UTC().Before(expires) {
		return errors.New("pending approval expired")
	}
	changed := record.ApprovedAt == ""
	if changed {
		record.ApprovedAt = isoUTC(time.Now())
		if err := service.writeDeviceRecord(record); err != nil {
			return err
		}
		service.audit("device approved", "fingerprint", fingerprint, "device_name", record.DeviceName)
	}
	return json.NewEncoder(output).Encode(map[string]any{"ok": true, "fingerprint": fingerprint, "changed": changed})
}
