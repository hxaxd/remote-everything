package main

import (
	"errors"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

var statusClientFingerprint = regexp.MustCompile(`^[a-f0-9]{64}$`)

func (service *publicService) readControlToken() (string, error) {
	contents, err := os.ReadFile(service.paths.controlTokenFile)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(contents))
	if !validHex64.MatchString(token) {
		return "", errors.New("invalid control token")
	}
	return token, nil
}

func requestFingerprint(request *http.Request) string {
	return strings.ToLower(strings.TrimSpace(request.Header.Get(clientFingerprintHeader)))
}

func (service *publicService) statusAuthorized(request *http.Request) bool {
	fingerprint := requestFingerprint(request)
	if !statusClientFingerprint.MatchString(fingerprint) {
		return false
	}
	record, err := service.loadDeviceRecord(fingerprint)
	return err == nil && record.Status == "approved"
}

func (service *publicService) activateDevice(request *http.Request) (any, string, error) {
	fingerprint := requestFingerprint(request)
	if !statusClientFingerprint.MatchString(fingerprint) {
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
	}
	apps, connected := service.gateway.ConnectedList()
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
			logLine("gateway", "warn", "remove completed invitation failed", "code", err.Error())
		}
		auditLine("device activated", "fingerprint", fingerprint, "device_name", record.DeviceName)
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

func (service *publicService) statusHTTPHandler(writer http.ResponseWriter, request *http.Request) {
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
		apps, code, err := service.activateDevice(request)
		if err != nil {
			status := http.StatusUnauthorized
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
	service.gateway.ServeHTTP(writer, request)
}

func (service *publicService) newStatusServer() (*http.Server, error) {
	token, err := service.readControlToken()
	if err != nil {
		return nil, err
	}
	service.gateway, err = gatewaycore.New("http://"+service.config.NodeTunnelListen, token)
	if err != nil {
		return nil, err
	}
	return &http.Server{
		Addr: service.config.StatusListen, Handler: http.HandlerFunc(service.statusHTTPHandler),
		ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second,
	}, nil
}
