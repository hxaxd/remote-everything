package devicecore

import (
	"errors"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

func requestFingerprint(request *http.Request) string {
	return strings.ToLower(strings.TrimSpace(request.Header.Get(clientFingerprintHeader)))
}

func (service *Trust) statusAuthorized(request *http.Request) bool {
	fingerprint := requestFingerprint(request)
	if !validHex64.MatchString(fingerprint) {
		return false
	}
	record, err := service.loadDeviceRecord(fingerprint)
	return err == nil && record.Status == "approved"
}

func (service *Trust) activateDevice(request *http.Request) (any, string, error) {
	fingerprint := requestFingerprint(request)
	if !validHex64.MatchString(fingerprint) {
		return nil, "unauthorized", errors.New("missing device fingerprint")
	}
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || record.Status == "revoked" {
		return nil, "unauthorized", errors.New("device unavailable")
	}
	if record.Status == "pending" {
		expires, parseErr := parseTimestamp(record.PendingExpiresAt)
		if parseErr != nil || !time.Now().UTC().Before(expires) {
			return nil, "invitation_expired", errors.New("pending device expired")
		}
		if record.ApprovalRequestedAt == "" {
			record.ApprovalRequestedAt = isoUTC(time.Now())
			if err := service.writeDeviceRecord(record); err != nil {
				return nil, "activation_failed", err
			}
			service.audit("device approval requested", "fingerprint", fingerprint, "device_name", record.DeviceName)
		}
		if record.ApprovedAt == "" {
			return nil, "approval_pending", errors.New("device approval pending")
		}
	}
	apps, connected := service.node.ConnectedList()
	if !connected {
		return nil, "computer_offline", errors.New("node validation failed")
	}
	if record.Status == "pending" {
		transaction, transactionPath, err := service.invitationTransaction(fingerprint)
		if err != nil {
			return nil, "activation_failed", errors.New("pending invitation transaction unavailable")
		}
		if transaction.ReplacesFingerprint != "" {
			replaced, err := service.loadDeviceRecord(transaction.ReplacesFingerprint)
			if err != nil || (replaced.Status != "approved" && (replaced.Status != "revoked" || replaced.ReplacedByFingerprint != fingerprint)) {
				return nil, "activation_failed", errors.New("renewed device unavailable")
			}
			if replaced.Status == "approved" {
				replaced.Status = "revoked"
				replaced.RevokedAt = isoUTC(time.Now())
				replaced.ReplacedByFingerprint = fingerprint
				if err := service.writeDeviceRecord(replaced); err != nil {
					return nil, "activation_failed", err
				}
			}
		}
		record.Status = "approved"
		record.ActivatedAt = isoUTC(time.Now())
		record.PendingExpiresAt = ""
		if err := service.writeDeviceRecord(record); err != nil {
			return nil, "activation_failed", err
		}
		if err := os.Remove(transactionPath); err != nil {
			service.log("gateway", "warn", "remove completed invitation failed", "code", err.Error())
		}
		service.audit("device activated", "fingerprint", fingerprint, "device_name", record.DeviceName)
	}
	return apps, "", nil
}

func rawRequestPath(request *http.Request) string {
	path := request.URL.EscapedPath()
	if path == "" {
		return "/"
	}
	return path
}

func (service *Trust) statusHTTPHandler(writer http.ResponseWriter, request *http.Request) {
	path := rawRequestPath(request)
	if path == "/healthz" && request.Method == http.MethodGet {
		gatewaycore.WriteJSON(writer, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	if path == "/__local_remote_control" {
		gatewaycore.WriteJSON(writer, http.StatusForbidden, gatewaycore.Error("forbidden"))
		return
	}
	if path == "/__remote_everything_activate" && request.Method == http.MethodPost {
		if !service.statusLimiter.allow(clientIP(request)) {
			gatewaycore.WriteJSON(writer, http.StatusTooManyRequests, gatewaycore.Error("rate_limited"))
			return
		}
		apps, code, err := service.activateDevice(request)
		if err != nil {
			status := http.StatusUnauthorized
			if code == "approval_pending" {
				status = http.StatusAccepted
			}
			if code == "computer_offline" || code == "activation_failed" {
				status = http.StatusServiceUnavailable
			}
			gatewaycore.WriteJSON(writer, status, gatewaycore.Error(code))
			return
		}
		gatewaycore.WriteJSON(writer, http.StatusOK, apps)
		return
	}
	if !service.statusAuthorized(request) {
		gatewaycore.WriteJSON(writer, http.StatusUnauthorized, gatewaycore.Error("unauthorized"))
		return
	}
	service.node.ServeHTTP(writer, request)
}
