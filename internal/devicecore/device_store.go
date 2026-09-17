package devicecore

import (
	"encoding/json"
	"errors"
	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
)

const recordSchema = 1

// deviceRecord is one device of this gateway. What it may reach is the list of
// nodes it was granted: a device's permission is here and nowhere else, so
// granting one more node, withdrawing one, and asking what a device may reach all
// read and write this one field.
type deviceRecord struct {
	Schema                 int      `json:"schema"`
	DeviceName             string   `json:"device_name"`
	CertificateFingerprint string   `json:"certificate_fingerprint"`
	Nodes                  []string `json:"nodes"`
	Status                 string   `json:"status"`
	CreatedAt              string   `json:"created_at"`
	CertificateExpiresAt   string   `json:"certificate_expires_at"`
	PendingExpiresAt       string   `json:"pending_expires_at,omitempty"`
	ApprovalRequestedAt    string   `json:"approval_requested_at,omitempty"`
	ApprovedAt             string   `json:"approved_at,omitempty"`
	ActivatedAt            string   `json:"activated_at,omitempty"`
	RevokedAt              string   `json:"revoked_at,omitempty"`
	ReplacedByFingerprint  string   `json:"replaced_by_fingerprint,omitempty"`
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
	// A device always says which nodes it holds, even when that is none: a record
	// that does not is a record whose permissions were not written down.
	if record.Nodes == nil {
		return errors.New("invalid device record nodes")
	}
	seenNodes := map[string]bool{}
	for _, nodeID := range record.Nodes {
		if !validHex64.MatchString(nodeID) || seenNodes[nodeID] {
			return errors.New("invalid device record nodes")
		}
		seenNodes[nodeID] = true
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
		records = append(records, record)
	}
	sort.Slice(records, func(i, j int) bool { return records[i].CreatedAt < records[j].CreatedAt })
	return records, nil
}

func (service *Trust) deviceList(output io.Writer) error {
	records, err := service.loadDeviceRecords()
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(records)
}

// deviceGrant grants an approved device one more node. The operator who runs it
// is the approval: the device already holds a credential for this gateway, so one
// more node is not something it has to be admitted to again.
func (service *Trust) deviceGrant(fingerprint, nodeID string, output io.Writer) error {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || record.Status != "approved" {
		return errors.New("approved fingerprint not found")
	}
	if _, ok := service.nodeByID(nodeID); !ok {
		return errors.New("node not found")
	}
	changed := !slices.Contains(record.Nodes, nodeID)
	if changed {
		record.Nodes = append(slices.Clone(record.Nodes), nodeID)
		if err := service.writeDeviceRecord(record); err != nil {
			return err
		}
		service.audit("device granted a node", "fingerprint", fingerprint, "node_id", nodeID)
	}
	return json.NewEncoder(output).Encode(map[string]any{"ok": true, "fingerprint": fingerprint, "node_id": nodeID, "changed": changed})
}

// deviceRevoke withdraws access from a device this gateway admitted. Without a
// node it withdraws the device itself: the credential it holds stops being
// admitted anywhere. With one it withdraws that node alone, which is how an
// operator takes one machine away from a device it keeps.
func (service *Trust) deviceRevoke(fingerprint, nodeID string, output io.Writer) error {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || record.Status == "pending" {
		return errors.New("approved fingerprint not found")
	}
	if nodeID != "" {
		index := slices.Index(record.Nodes, nodeID)
		if index < 0 {
			return json.NewEncoder(output).Encode(map[string]any{"ok": true, "fingerprint": fingerprint, "node_id": nodeID, "changed": false})
		}
		record.Nodes = slices.Delete(slices.Clone(record.Nodes), index, index+1)
		if err := service.writeDeviceRecord(record); err != nil {
			return err
		}
		service.audit("device revoked from a node", "fingerprint", fingerprint, "node_id", nodeID)
		return json.NewEncoder(output).Encode(map[string]any{"ok": true, "fingerprint": fingerprint, "node_id": nodeID, "changed": true})
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

// ForgetNode takes a node out of every device of this gateway, and reports which
// devices it was taken out of. A node the gateway no longer serves is not something
// any device may reach, and a device's node list is the only place that reach is
// written down, so it is edited where it lives: a permission that is written
// somewhere else is a permission that outlives what it was for.
func (service *Trust) ForgetNode(nodeID string) ([]string, error) {
	if !validHex64.MatchString(nodeID) {
		return nil, errors.New("invalid node id")
	}
	records, err := service.loadDeviceRecords()
	if err != nil {
		return nil, err
	}
	changed := make([]string, 0, len(records))
	for _, record := range records {
		index := slices.Index(record.Nodes, nodeID)
		if index < 0 {
			continue
		}
		record.Nodes = slices.Delete(slices.Clone(record.Nodes), index, index+1)
		if err := service.writeDeviceRecord(record); err != nil {
			return nil, err
		}
		service.audit("device no longer holds a removed node", "fingerprint", record.CertificateFingerprint, "node_id", nodeID)
		changed = append(changed, record.CertificateFingerprint)
	}
	return changed, nil
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
