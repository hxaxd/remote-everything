package entrancetest

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

// CheckEmpty drives a newly initialized or restarted empty entrance through its
// actual listening surface. Empty node membership does not bypass device trust.
func CheckEmpty(t *testing.T, harness Harness) {
	t.Helper()
	if nodes := harness.Gateway().State().Nodes; nodes == nil || len(nodes) != 0 {
		t.Fatalf("expected an empty gateway, got %+v", nodes)
	}
	if status, body, err := harness.Dial(nil, http.MethodGet, "/healthz", nil, nil); err != nil || status != http.StatusOK {
		t.Fatalf("empty gateway health: %d %s %v", status, body, err)
	}
	if status, body, err := harness.Dial(nil, http.MethodGet, "/__remote_everything/nodes", nil, nil); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("anonymous empty directory: %d %s %v", status, body, err)
	}
	for _, command := range [][]string{{"list"}, {"invitation", "list"}} {
		output, err := runCLI(harness.Gateway().Trust(), command...)
		if err != nil || !json.Valid([]byte(output)) {
			t.Fatalf("empty gateway device %v: %s %v", command, output, err)
		}
	}
}

// RunEmptyLifecycle is shared by both gateway shapes: admit a real device,
// remove every node and restart, keep management available, then add a node back.
func RunEmptyLifecycle(t *testing.T, harness Harness, empty, repopulate func()) {
	t.Helper()
	first := harness.Gateway().State().Nodes[0]
	fingerprint, credential := pair(t, harness, issueInvitation(t, harness, first))
	admit(t, harness, fingerprint, credential, first)
	empty()
	CheckEmpty(t, harness)
	status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/nodes", nil, nil)
	var directory struct {
		OK    bool              `json:"ok"`
		Nodes []json.RawMessage `json:"nodes"`
	}
	if err != nil || status != http.StatusOK || json.Unmarshal([]byte(body), &directory) != nil || !directory.OK || directory.Nodes == nil || len(directory.Nodes) != 0 {
		t.Fatalf("approved device's empty directory: %d %s %v", status, body, err)
	}
	if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", map[string]string{proxysecurity.NodeHeader: first.ID}, nil); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("removed node still accessible: %d %s %v", status, body, err)
	}
	listed, err := runCLI(harness.Gateway().Trust(), "list")
	var records []struct {
		Fingerprint string   `json:"certificate_fingerprint"`
		Status      string   `json:"status"`
		Nodes       []string `json:"nodes"`
	}
	if err != nil || json.Unmarshal([]byte(listed), &records) != nil || len(records) != 1 || records[0].Fingerprint != fingerprint || records[0].Status != "approved" || records[0].Nodes == nil || len(records[0].Nodes) != 0 {
		t.Fatalf("empty gateway device list: %s %v", listed, err)
	}
	if output, err := runCLI(harness.Gateway().Trust(), "revoke", fingerprint); err != nil {
		t.Fatalf("empty gateway could not revoke: %s %v", output, err)
	}
	if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/nodes", nil, nil); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("empty gateway accepted revoked device: %d %s %v", status, body, err)
	}
	repopulate()
	if nodes := harness.Gateway().State().Nodes; len(nodes) != 1 || nodes[0].ID != first.ID {
		t.Fatalf("repopulated gateway nodes: %+v", nodes)
	}
	if status, body, err := harness.Dial(credential, http.MethodGet, "/__remote_everything/apps", map[string]string{proxysecurity.NodeHeader: first.ID}, nil); err != nil || status != http.StatusUnauthorized {
		t.Fatalf("adding a node restored revoked access: %d %s %v", status, body, err)
	}
	newFingerprint, newCredential := pair(t, harness, issueInvitation(t, harness, first))
	admit(t, harness, newFingerprint, newCredential, first)
}
