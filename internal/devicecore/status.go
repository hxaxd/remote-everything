package devicecore

import (
	"errors"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

func requestFingerprint(request *http.Request) string {
	return strings.ToLower(strings.TrimSpace(request.Header.Get(clientFingerprintHeader)))
}

// authorizedDevice is the device a request speaks for: the one whose certificate
// the entrance verified and whose record this gateway holds as admitted. Anything
// else is a request this gateway cannot act for.
func (service *Trust) authorizedDevice(request *http.Request) (deviceRecord, bool) {
	fingerprint := requestFingerprint(request)
	if !validHex64.MatchString(fingerprint) {
		return deviceRecord{}, false
	}
	record, err := service.loadDeviceRecord(fingerprint)
	return record, err == nil && record.Status == "approved"
}

// nodeByID returns a node this gateway serves. It is what a request names a node
// by, and it is exact: a request carries an id, never a name.
func (service *Trust) nodeByID(nodeID string) (gatewaycore.Node, bool) {
	return gatewaycore.FindNode(service.node.Nodes(), nodeID)
}

// nodeForRequest returns the node a request is for, when this gateway serves it
// and the device behind the request may reach it. It answers with the code a
// refusal is written as, because a request that names no node and one that names
// a node this device cannot reach have no answer here: which nodes exist is not
// something a device that cannot reach one learns from asking for it.
func (service *Trust) nodeForRequest(request *http.Request, record deviceRecord) (gatewaycore.Node, string, error) {
	nodeID := strings.TrimSpace(request.Header.Get(proxysecurity.NodeHeader))
	if !validHex64.MatchString(nodeID) {
		return gatewaycore.Node{}, "node_required", errors.New("request names no node")
	}
	node, ok := service.nodeByID(nodeID)
	if !ok || !slices.Contains(record.Nodes, node.ID) {
		return gatewaycore.Node{}, "unauthorized", errors.New("node not granted")
	}
	return node, "", nil
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
	// The node is resolved before anything is written about the device, so a device
	// that asks about a node it cannot reach leaves no trace of having asked.
	node, code, err := service.nodeForRequest(request, record)
	if err != nil {
		return nil, code, err
	}
	if record.Status == "pending" {
		expires, parseErr := parseTimestamp(record.PendingExpiresAt)
		if parseErr != nil || !time.Now().UTC().Before(expires) {
			return nil, "invitation_expired", errors.New("pending device expired")
		}
		if service.approveOnRedemption {
			// This gateway's admission is the invitation itself: the operator who
			// handed it over is the one who approves the device, so it asks and is
			// granted in the same instant and there is nobody to wait for.
			if record.ApprovedAt == "" {
				now := isoUTC(time.Now())
				record.ApprovalRequestedAt = now
				record.ApprovedAt = now
				if err := service.writeDeviceRecord(record); err != nil {
					return nil, "activation_failed", err
				}
				service.audit("device approved by invitation", "fingerprint", fingerprint, "device_name", record.DeviceName)
			}
		} else {
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
	}
	apps, connected := service.node.ConnectedList(node.ID)
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

// nodeEntry is one node of the answer to "which nodes may I reach", as a client
// reads it: what to ask for, and what to show.
type nodeEntry struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type nodeListResponse struct {
	OK    bool        `json:"ok"`
	Nodes []nodeEntry `json:"nodes"`
}

// nodeList is the answer to "which nodes may this device reach": the nodes this
// gateway serves that the device was granted, which is how a device that was
// granted one more node finds out about it without pairing again.
func (service *Trust) nodeList(record deviceRecord) nodeListResponse {
	nodes := []nodeEntry{}
	for _, node := range service.node.Nodes() {
		if slices.Contains(record.Nodes, node.ID) {
			nodes = append(nodes, nodeEntry{ID: node.ID, Name: node.Name})
		}
	}
	return nodeListResponse{OK: true, Nodes: nodes}
}

func (service *Trust) statusHTTPHandler(writer http.ResponseWriter, request *http.Request) {
	path := rawRequestPath(request)
	if path == "/healthz" && request.Method == http.MethodGet {
		gatewaycore.WriteJSON(writer, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	// The entrance in front of this gateway asks this in its own name, without a
	// device credential, and it is answered on its own: what it asks about is not
	// anything a device owns, and the question is answered by this gateway rather
	// than by any node.
	if path == TLSAskPath {
		service.answerTLSPermission(writer, request)
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
	record, ok := service.authorizedDevice(request)
	if !ok {
		gatewaycore.WriteJSON(writer, http.StatusUnauthorized, gatewaycore.Error("unauthorized"))
		return
	}
	// Which nodes there are is the gateway's answer; which of them this device may
	// reach is this trust's, and this is the only place the two are put together.
	// It is asked without naming a node, because it is how a device finds out which
	// ones it has: naming one is what needing the answer would be.
	if path == "/__remote_everything/nodes" && request.Method == http.MethodGet {
		gatewaycore.WriteJSON(writer, http.StatusOK, service.nodeList(record))
		return
	}
	node, code, err := service.nodeForRequest(request, record)
	if err != nil {
		gatewaycore.WriteJSON(writer, http.StatusUnauthorized, gatewaycore.Error(code))
		return
	}
	// What a request names has been read and permitted; the gateway is handed the
	// node that was decided on, and everything from here is that node answering.
	service.node.ServeNode(node.ID, writer, request)
}

// WebDeviceState describes the authorization state of a web device.
type WebDeviceState struct {
	Fingerprint string   `json:"fingerprint"`
	DeviceName  string   `json:"device_name"`
	Status      string   `json:"status"`
	Nodes       []string `json:"nodes"`
}

// ActivateWebDevice checks or activates a web client device by fingerprint.
func (service *Trust) ActivateWebDevice(fingerprint string) (WebDeviceState, string, error) {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	if !validHex64.MatchString(fingerprint) {
		return WebDeviceState{}, "unauthorized", errors.New("missing device fingerprint")
	}
	record, err := service.loadDeviceRecord(fingerprint)
	if err != nil || record.Status == "revoked" {
		return WebDeviceState{}, "unauthorized", errors.New("device unavailable")
	}
	if record.Status == "pending" {
		expires, parseErr := parseTimestamp(record.PendingExpiresAt)
		if parseErr != nil || !time.Now().UTC().Before(expires) {
			return WebDeviceState{}, "invitation_expired", errors.New("pending device expired")
		}
		if service.approveOnRedemption {
			if record.ApprovedAt == "" {
				now := isoUTC(time.Now())
				record.ApprovalRequestedAt = now
				record.ApprovedAt = now
				record.Status = "approved"
				record.ActivatedAt = now
				record.PendingExpiresAt = ""
				if err := service.writeDeviceRecord(record); err != nil {
					return WebDeviceState{}, "activation_failed", err
				}
				service.audit("web device approved by invitation", "fingerprint", fingerprint, "device_name", record.DeviceName)
			}
		} else {
			if record.ApprovalRequestedAt == "" {
				record.ApprovalRequestedAt = isoUTC(time.Now())
				if err := service.writeDeviceRecord(record); err != nil {
					return WebDeviceState{}, "activation_failed", err
				}
				service.audit("web device approval requested", "fingerprint", fingerprint, "device_name", record.DeviceName)
			}
			if record.ApprovedAt == "" {
				return WebDeviceState{
					Fingerprint: fingerprint,
					DeviceName:  record.DeviceName,
					Status:      "pending",
					Nodes:       record.Nodes,
				}, "approval_pending", errors.New("device approval pending")
			}
			record.Status = "approved"
			record.ActivatedAt = isoUTC(time.Now())
			record.PendingExpiresAt = ""
			if err := service.writeDeviceRecord(record); err != nil {
				return WebDeviceState{}, "activation_failed", err
			}
			service.audit("web device activated", "fingerprint", fingerprint, "device_name", record.DeviceName)
		}
	}
	return WebDeviceState{
		Fingerprint: fingerprint,
		DeviceName:  record.DeviceName,
		Status:      record.Status,
		Nodes:       record.Nodes,
	}, "", nil
}
