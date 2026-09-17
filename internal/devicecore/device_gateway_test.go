package devicecore

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

// admitted is a device this gateway admitted, and the nodes it holds: one from
// the invitation it redeemed.
func admitted(t *testing.T, fixture *gatewayFixture, index int) string {
	t.Helper()
	paired := fixture.pair(t, index)
	fixture.admit(t, paired.CertificateFingerprint, index)
	return paired.CertificateFingerprint
}

func TestStatusAuthorizationAndRoutes(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	if result := nodeRequest(fixture.trust, http.MethodGet, "/healthz", "", ""); result.Code != http.StatusOK {
		t.Fatalf("health status = %d", result.Code)
	}
	if result := nodeRequest(fixture.trust, http.MethodGet, "/__remote_everything/apps", "", testNodeIDs[0]); result.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized apps status = %d", result.Code)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 0); result.Code != http.StatusOK || !strings.Contains(result.Body.String(), "fixture") {
		t.Fatalf("apps response = %d %s", result.Code, result.Body.String())
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/open/fixture", fingerprint, 0); result.Code != http.StatusFound {
		t.Fatalf("open status = %d", result.Code)
	}
	if result := fixture.request(http.MethodPost, "/__remote_everything/apps/fixture/start", fingerprint, 0); result.Code != http.StatusOK {
		t.Fatalf("start status = %d", result.Code)
	}
}

// A device is admitted to the nodes it holds and to nothing else, and the node it
// is not admitted to never hears about the request.
func TestADeviceReachesOnlyTheNodesItHolds(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 1); result.Code != http.StatusUnauthorized || !strings.Contains(result.Body.String(), `"unauthorized"`) {
		t.Fatalf("a device reached a node it does not hold: %d %s", result.Code, result.Body.String())
	}
	if saw := fixture.nodes[1].saw(); len(saw) != 0 {
		t.Fatalf("the node a device does not hold was asked anyway: %v", saw)
	}
	if result := fixture.request(http.MethodGet, "/page/", fingerprint, 1); result.Code != http.StatusUnauthorized {
		t.Fatalf("a page of a node a device does not hold was served: %d", result.Code)
	}
	if saw := fixture.nodes[1].saw(); len(saw) != 0 {
		t.Fatalf("a page of the node a device does not hold reached it: %v", saw)
	}
}

// A request that names no node is refused, and so is one that names a node this
// gateway does not serve: neither is answered by guessing which node was meant.
func TestARequestWithoutANodeOfThisGatewayIsRefused(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	// Admitting the device is what asked node 0 for its catalog; what is asserted
	// here is that these refusals ask neither node anything more.
	before := []int{len(fixture.nodes[0].saw()), len(fixture.nodes[1].saw())}
	for nodeID, wantCode := range map[string]string{"": "node_required", strings.Repeat("99", 32): "unauthorized"} {
		result := nodeRequest(fixture.trust, http.MethodGet, "/__remote_everything/apps", fingerprint, nodeID)
		if result.Code != http.StatusUnauthorized || !strings.Contains(result.Body.String(), `"`+wantCode+`"`) {
			t.Fatalf("a request naming %q was answered with %d %s", nodeID, result.Code, result.Body.String())
		}
	}
	for index := range fixture.nodes {
		if saw := fixture.nodes[index].saw(); len(saw) != before[index] {
			t.Fatalf("node %d answered a request that named no node of it: %v", index, saw[before[index]:])
		}
	}
}

// Activation is for one node, and a device that asks about a node it cannot reach
// leaves no trace of having asked: nothing is written about it before the node it
// names is resolved.
func TestActivationForANodeTheDeviceDoesNotHoldLeavesNoTrace(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	paired := fixture.pair(t, 0)
	for nodeID, wantCode := range map[string]string{testNodeIDs[1]: "unauthorized", "": "node_required", strings.Repeat("99", 32): "unauthorized"} {
		request := httptest.NewRequest(http.MethodPost, "/__remote_everything_activate", nil)
		request.Header.Set(clientFingerprintHeader, paired.CertificateFingerprint)
		request.Header.Set(proxysecurity.NodeHeader, nodeID)
		if _, code, err := fixture.trust.activateDevice(request); err == nil || code != wantCode {
			t.Fatalf("activation for %q answered %s %v", nodeID, code, err)
		}
	}
	record, err := fixture.trust.loadDeviceRecord(paired.CertificateFingerprint)
	if err != nil || record.Status != "pending" || record.ApprovalRequestedAt != "" || record.ApprovedAt != "" {
		t.Fatalf("a refused activation changed the device: %+v %v", record, err)
	}
	if saw := fixture.nodes[1].saw(); len(saw) != 0 {
		t.Fatalf("a node a device does not hold was asked about it: %v", saw)
	}
}

// What a device may reach is one list, and this is where a device reads it: it is
// how a device that was granted one more node finds out without pairing again.
func TestNodesListIsWhatTheDeviceHolds(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	listed := func() nodeListResponse {
		t.Helper()
		result := fixture.request(http.MethodGet, "/__remote_everything/nodes", fingerprint, 0)
		if result.Code != http.StatusOK {
			t.Fatalf("listing nodes answered %d %s", result.Code, result.Body.String())
		}
		var body nodeListResponse
		if err := json.Unmarshal(result.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		return body
	}
	if body := listed(); !body.OK || len(body.Nodes) != 1 || body.Nodes[0].ID != testNodeIDs[0] || body.Nodes[0].Name != testNodeNames[0] {
		t.Fatalf("a device holds %+v", body)
	}
	if result := nodeRequest(fixture.trust, http.MethodGet, "/__remote_everything/nodes", "", ""); result.Code != http.StatusUnauthorized {
		t.Fatalf("a device that was never admitted listed nodes: %d", result.Code)
	}
	// A node granted afterwards is reachable without pairing again, and the device
	// finds out by asking.
	if err := fixture.trust.deviceGrant(fingerprint, testNodeIDs[1], io.Discard); err != nil {
		t.Fatal(err)
	}
	if body := listed(); len(body.Nodes) != 2 || body.Nodes[1].ID != testNodeIDs[1] || body.Nodes[1].Name != testNodeNames[1] {
		t.Fatalf("a granted node is not listed: %+v", body)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 1); result.Code != http.StatusOK {
		t.Fatalf("a granted node was not reachable: %d %s", result.Code, result.Body.String())
	}
	// Granting what a device already holds changes nothing, and is not an error.
	var repeated strings.Builder
	if err := fixture.trust.deviceGrant(fingerprint, testNodeIDs[1], &repeated); err != nil || !strings.Contains(repeated.String(), `"changed":false`) {
		t.Fatalf("repeat grant is not idempotent: %s %v", repeated.String(), err)
	}
	// A node this gateway does not serve is not something to grant.
	if err := fixture.trust.deviceGrant(fingerprint, strings.Repeat("99", 32), io.Discard); err == nil {
		t.Fatal("a node this gateway does not serve was granted")
	}
	if err := fixture.trust.deviceGrant(strings.Repeat("ef", 32), testNodeIDs[1], io.Discard); err == nil {
		t.Fatal("a device that is not approved was granted a node")
	}
}

// Withdrawing one node leaves the rest of what a device holds, and withdrawing the
// device leaves it nothing.
func TestRevokingIsPerNodeOrOfTheWholeDevice(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	if err := fixture.trust.deviceGrant(fingerprint, testNodeIDs[1], io.Discard); err != nil {
		t.Fatal(err)
	}
	var output strings.Builder
	if err := fixture.trust.deviceRevoke(fingerprint, testNodeIDs[1], &output); err != nil || !strings.Contains(output.String(), `"changed":true`) {
		t.Fatalf("withdrawing a node answered %s %v", output.String(), err)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 1); result.Code != http.StatusUnauthorized {
		t.Fatalf("a withdrawn node was still reachable: %d", result.Code)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 0); result.Code != http.StatusOK {
		t.Fatalf("withdrawing one node took another away: %d %s", result.Code, result.Body.String())
	}
	record, err := fixture.trust.loadDeviceRecord(fingerprint)
	if err != nil || record.Status != "approved" || len(record.Nodes) != 1 {
		t.Fatalf("withdrawing one node changed the device: %+v %v", record, err)
	}
	output.Reset()
	if err := fixture.trust.deviceRevoke(fingerprint, testNodeIDs[1], &output); err != nil || !strings.Contains(output.String(), `"changed":false`) {
		t.Fatalf("repeat withdrawal is not idempotent: %s %v", output.String(), err)
	}
	output.Reset()
	if err := fixture.trust.deviceRevoke(fingerprint, "", &output); err != nil {
		t.Fatal(err)
	}
	for index := range fixture.nodes {
		if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, index); result.Code != http.StatusUnauthorized {
			t.Fatalf("a revoked device still reached node %d: %d", index, result.Code)
		}
	}
}

func TestApplicationProxyStripsInternalHeaders(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	request := httptest.NewRequest(http.MethodGet, "/page", nil)
	request.Header.Set(clientFingerprintHeader, fingerprint)
	request.Header.Set(proxysecurity.NodeHeader, testNodeIDs[0])
	request.Header.Set("Authorization", "secret")
	recorder := httptest.NewRecorder()
	fixture.trust.statusHTTPHandler(recorder, request)
	if recorder.Code != http.StatusOK || recorder.Body.String() != "proxied" {
		t.Fatalf("proxy response = %d %q", recorder.Code, recorder.Body.String())
	}
}

// A node's control plane is reached by the gateway that serves it, with the token
// it holds for it, and never through the proxy that serves its applications —
// whichever device asks and whatever it is admitted to.
func TestTheControlPlaneIsNeverProxied(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	before := len(fixture.nodes[0].saw())
	for _, path := range []string{proxysecurity.ControlPath, "/%5f%5flocal_remote_control"} {
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.Header.Set(clientFingerprintHeader, fingerprint)
		request.Header.Set(proxysecurity.NodeHeader, testNodeIDs[0])
		recorder := httptest.NewRecorder()
		fixture.trust.statusHTTPHandler(recorder, request)
		if recorder.Code != http.StatusForbidden {
			t.Fatalf("%s reached the node with %d %s", path, recorder.Code, recorder.Body.String())
		}
	}
	if saw := fixture.nodes[0].saw(); len(saw) != before {
		t.Fatalf("a node's control plane was asked through the proxy: %v", saw)
	}
	// Without a credential it is not answered as the control plane at all: it is
	// refused the way every other request from a client with none is.
	request := httptest.NewRequest(http.MethodGet, proxysecurity.ControlPath, nil)
	recorder := httptest.NewRecorder()
	fixture.trust.statusHTTPHandler(recorder, request)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("an unauthenticated control request answered %d", recorder.Code)
	}
}

// A node that is taken out of the gateway is taken out of every device's reach: a
// device's node list is where that reach is written down, and a permission for a
// machine the gateway no longer serves has to go with it.
func TestForgettingANodeTakesItFromEveryDevice(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	if err := fixture.trust.deviceGrant(fingerprint, testNodeIDs[1], io.Discard); err != nil {
		t.Fatal(err)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 1); result.Code != http.StatusOK {
		t.Fatalf("the granted node is not reachable: %d", result.Code)
	}
	changed, err := fixture.trust.ForgetNode(testNodeIDs[1])
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 1 || changed[0] != fingerprint {
		t.Fatalf("forgetting a node changed %v", changed)
	}
	record, err := fixture.trust.loadDeviceRecord(fingerprint)
	if err != nil || len(record.Nodes) != 1 || record.Nodes[0] != testNodeIDs[0] {
		t.Fatalf("the device holds %v (%v)", record.Nodes, err)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 1); result.Code != http.StatusUnauthorized {
		t.Fatalf("a node that was taken away was still reachable: %d", result.Code)
	}
	if result := fixture.request(http.MethodGet, "/__remote_everything/apps", fingerprint, 0); result.Code != http.StatusOK {
		t.Fatalf("forgetting one node took another away: %d", result.Code)
	}
	// A node nobody holds is forgotten without touching anything.
	if changed, err := fixture.trust.ForgetNode(testNodeIDs[1]); err != nil || len(changed) != 0 {
		t.Fatalf("forgetting an unheld node changed %v (%v)", changed, err)
	}
}

// A device asks which nodes it may reach without naming one: naming a node is what
// needing the answer would be, and a device that was granted one more node has no
// other way to find out about it.
func TestListingReachableNodesNamesNoNode(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	if err := fixture.trust.deviceGrant(fingerprint, testNodeIDs[1], io.Discard); err != nil {
		t.Fatal(err)
	}
	result := nodeRequest(fixture.trust, http.MethodGet, "/__remote_everything/nodes", fingerprint, "")
	if result.Code != http.StatusOK {
		t.Fatalf("listing what a device may reach answered %d %s", result.Code, result.Body.String())
	}
	var payload struct {
		OK    bool `json:"ok"`
		Nodes []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"nodes"`
	}
	if err := json.Unmarshal(result.Body.Bytes(), &payload); err != nil || !payload.OK || len(payload.Nodes) != 2 {
		t.Fatalf("node list is %s (%v)", result.Body.String(), err)
	}
	for index, node := range payload.Nodes {
		if node.ID != testNodeIDs[index] || node.Name != testNodeNames[index] {
			t.Fatalf("node %d of the answer is %+v", index, node)
		}
	}
}

// Approving a device means what this gateway's admission means, and saying which
// it is beats reporting a device that is not waiting: where the invitation is the
// approval there is nothing to approve, and where an operator confirms devices
// there is.
func TestApprovingSaysWhetherItHasAnythingToDo(t *testing.T) {
	inline := newGatewayFixture(t, true)
	paired := inline.pair(t, 0)
	var output strings.Builder
	if err := inline.trust.RunCLI([]string{"approve", paired.CertificateFingerprint}, &output); err == nil {
		t.Fatalf("a gateway that admits on redemption approved something: %s", output.String())
	} else if !strings.Contains(err.Error(), "nothing to approve") {
		t.Fatalf("approving on redemption was refused with %v", err)
	}

	// A gateway whose operator confirms devices admits by approval, and approving a
	// device that is already admitted is not an error: it has nothing left to do.
	operator := newGatewayFixture(t, false)
	fingerprint := admitted(t, operator, 0)
	output.Reset()
	if err := operator.trust.RunCLI([]string{"approve", fingerprint}, &output); err != nil {
		t.Fatalf("approving an admitted device failed: %v", err)
	}
	if !strings.Contains(output.String(), `"changed":false`) {
		t.Fatalf("approving an admitted device is not idempotent: %s", output.String())
	}
}

// An entrance hands its invitations over in person, so redeeming one is the whole
// of the admission: activation is what admits the device, for the node it holds.
func TestAnInlineAdmissionAdmitsOnActivation(t *testing.T) {
	fixture := newGatewayFixture(t, true)
	paired := fixture.pair(t, 0)
	if code, err := fixture.activate(paired.CertificateFingerprint, 0); err != nil || code != "" {
		t.Fatalf("activation was not admitted by the invitation: %s %v", code, err)
	}
	record, err := fixture.trust.loadDeviceRecord(paired.CertificateFingerprint)
	if err != nil || record.Status != "approved" || record.ApprovedAt == "" {
		t.Fatalf("the device was not admitted: %+v %v", record, err)
	}
	// And a device this gateway never saw is not admitted to anything.
	if code, err := fixture.activate(strings.Repeat("ef", 32), 0); err == nil || code != "unauthorized" {
		t.Fatalf("an unknown device was admitted: %s %v", code, err)
	}
}

// The device records a gateway keeps are what an operator reads, so a device's
// nodes are part of them rather than a second place permissions live.
func TestDeviceListReportsTheNodesADeviceHolds(t *testing.T) {
	fixture := newGatewayFixture(t, false)
	fingerprint := admitted(t, fixture, 0)
	var listed strings.Builder
	if err := fixture.trust.deviceList(&listed); err != nil {
		t.Fatal(err)
	}
	var records []deviceRecord
	if err := json.Unmarshal([]byte(listed.String()), &records); err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 || records[0].CertificateFingerprint != fingerprint || len(records[0].Nodes) != 1 || records[0].Nodes[0] != testNodeIDs[0] {
		t.Fatalf("device list is %s", listed.String())
	}
}
