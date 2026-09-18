package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/entrancetest"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/webclient"
)

// webTestClient returns an http.Client configured with a cookie jar and trusting
// the entrance's self-signed TLS certificate.
func newWebTestClient(t *testing.T, pinnedCert *x509.Certificate) (*http.Client, *cookiejar.Jar) {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    x509.NewCertPool(),
	}
	tlsConfig.RootCAs.AddCert(pinnedCert)

	client := &http.Client{
		Jar: jar,
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: 5 * time.Second,
	}
	return client, jar
}

// TestLANWebClient_StaticAssets verifies the embedded SPA static assets are correctly served.
func TestLANWebClient_StaticAssets(t *testing.T) {
	harness := startLANEntrance(t)
	client, _ := newWebTestClient(t, harness.pinned)

	tests := []struct {
		path        string
		wantStatus  int
		wantContent string
	}{
		{"/", http.StatusOK, "<title>Remote Everything Web</title>"},
		{"/index.html", http.StatusOK, "Remote Everything Web"},
		{"/style.css", http.StatusOK, "--bg-main"},
		{"/app.js", http.StatusOK, "CryptoVault"},
		{"/favicon.ico", http.StatusNoContent, ""},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			resp, err := client.Get(harness.origin + tt.path)
			if err != nil {
				t.Fatalf("GET %s failed: %v", tt.path, err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != tt.wantStatus {
				t.Fatalf("GET %s status = %d; want %d", tt.path, resp.StatusCode, tt.wantStatus)
			}
			body, _ := io.ReadAll(resp.Body)
			if tt.wantContent != "" && !strings.Contains(string(body), tt.wantContent) {
				t.Fatalf("GET %s content does not contain %q", tt.path, tt.wantContent)
			}
		})
	}
}

// TestLANWebClient_EndToEndFlow verifies the full Web client lifecycle:
// pairing -> nodes query -> apps query -> open app with ticket -> logout.
func TestLANWebClient_EndToEndFlow(t *testing.T) {
	harness := startLANEntrance(t)
	client, jar := newWebTestClient(t, harness.pinned)

	// 1. Unauthenticated request to /nodes should return 401
	resp, err := client.Get(harness.origin + "/__remote_everything/nodes")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /nodes status = %d; want %d", resp.StatusCode, http.StatusUnauthorized)
	}

	// 2. Issue invitation on the entrance
	var inviteOut bytes.Buffer
	if err := harness.service.trust.RunCLI([]string{"invite", "--name", "Test Web Browser", "--node", entrancetest.NodeIDs[0], "--ttl", "10m"}, &inviteOut); err != nil {
		t.Fatalf("failed to issue invitation: %v", err)
	}
	var inviteResult struct {
		Invitation string `json:"invitation"`
	}
	if err := json.Unmarshal(inviteOut.Bytes(), &inviteResult); err != nil {
		t.Fatalf("failed to decode invitation: %v", err)
	}

	// 3. Web pair request
	pairReqBody, _ := json.Marshal(map[string]string{
		"client_id":   "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
		"device_name": "Test Web Browser",
	})
	pairReq, err := http.NewRequest(http.MethodPost, harness.origin+"/__remote_everything_web_pair", bytes.NewReader(pairReqBody))
	if err != nil {
		t.Fatal(err)
	}
	pairReq.Header.Set("Authorization", "Invitation "+inviteResult.Invitation)
	pairReq.Header.Set("Content-Type", "application/json")

	pairResp, err := client.Do(pairReq)
	if err != nil {
		t.Fatalf("pair request failed: %v", err)
	}
	defer pairResp.Body.Close()

	if pairResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(pairResp.Body)
		t.Fatalf("pair request status = %d (body: %s); want %d", pairResp.StatusCode, string(body), http.StatusOK)
	}

	var pairData struct {
		OK           bool     `json:"ok"`
		DeviceName   string   `json:"device_name"`
		Fingerprint  string   `json:"fingerprint"`
		SessionToken string   `json:"session_token"`
		Status       string   `json:"status"`
		Nodes        []string `json:"nodes"`
	}
	if err := json.NewDecoder(pairResp.Body).Decode(&pairData); err != nil {
		t.Fatalf("failed to decode pair response: %v", err)
	}
	if !pairData.OK || pairData.Status != "approved" || pairData.SessionToken == "" {
		t.Fatalf("unexpected pair result: %+v", pairData)
	}

	// Verify cookie was saved in jar
	u, _ := url.Parse(harness.origin)
	cookies := jar.Cookies(u)
	hasWebCookie := false
	for _, c := range cookies {
		if c.Name == webclient.SessionCookieName && c.Value == pairData.SessionToken {
			hasWebCookie = true
			break
		}
	}
	if !hasWebCookie {
		t.Fatal("cookie jar missing session cookie after pairing")
	}

	// 4. Query /__remote_everything/nodes with web session cookie
	nodesResp, err := client.Get(harness.origin + "/__remote_everything/nodes")
	if err != nil {
		t.Fatal(err)
	}
	defer nodesResp.Body.Close()
	if nodesResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(nodesResp.Body)
		t.Fatalf("/nodes status = %d (body: %s); want %d", nodesResp.StatusCode, string(body), http.StatusOK)
	}
	var nodesList struct {
		OK    bool `json:"ok"`
		Nodes []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"nodes"`
	}
	if err := json.NewDecoder(nodesResp.Body).Decode(&nodesList); err != nil {
		t.Fatalf("failed to parse nodes response: %v", err)
	}
	if len(nodesList.Nodes) == 0 {
		t.Fatal("nodes list is empty")
	}
	if nodesList.Nodes[0].ID != entrancetest.NodeIDs[0] {
		t.Fatalf("expected node %s, got %v", entrancetest.NodeIDs[0], nodesList.Nodes[0].ID)
	}

	// 5. Query /__remote_everything/apps for the node
	appsReq, _ := http.NewRequest(http.MethodGet, harness.origin+"/__remote_everything/apps", nil)
	appsReq.Header.Set(proxysecurity.NodeHeader, entrancetest.NodeIDs[0])
	appsResp, err := client.Do(appsReq)
	if err != nil {
		t.Fatal(err)
	}
	defer appsResp.Body.Close()
	if appsResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(appsResp.Body)
		t.Fatalf("/apps status = %d (body: %s); want %d", appsResp.StatusCode, string(body), http.StatusOK)
	}
	var appsData struct {
		Apps []struct {
			ID string `json:"id"`
		} `json:"apps"`
	}
	if err := json.NewDecoder(appsResp.Body).Decode(&appsData); err != nil {
		t.Fatalf("failed to decode apps data: %v", err)
	}
	if len(appsData.Apps) == 0 || appsData.Apps[0].ID != "editor" {
		t.Fatalf("expected app editor, got %+v", appsData.Apps)
	}

	// 6. Open application: GET /__remote_everything/open/editor
	openReq, _ := http.NewRequest(http.MethodGet, harness.origin+"/__remote_everything/open/editor", nil)
	openReq.Header.Set(proxysecurity.NodeHeader, entrancetest.NodeIDs[0])
	openResp, err := client.Do(openReq)
	if err != nil {
		t.Fatal(err)
	}
	defer openResp.Body.Close()
	if openResp.StatusCode != http.StatusFound {
		t.Fatalf("open app status = %d; want %d", openResp.StatusCode, http.StatusFound)
	}
	location := openResp.Header.Get("Location")
	if location == "" {
		t.Fatal("open app redirect missing Location header")
	}
	if !strings.Contains(location, webclient.TicketQueryParam+"=") {
		t.Fatalf("expected Location to contain ticket query param %q, got: %s", webclient.TicketQueryParam, location)
	}

	// 7. Follow redirect to app origin using ticket
	appReq, err := http.NewRequest(http.MethodGet, location, nil)
	if err != nil {
		t.Fatal(err)
	}
	appResp, err := client.Do(appReq)
	if err != nil {
		t.Fatalf("visiting application origin failed: %v", err)
	}
	defer appResp.Body.Close()
	if appResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(appResp.Body)
		t.Fatalf("application origin returned status %d (body: %s); want %d", appResp.StatusCode, string(body), http.StatusOK)
	}

	// 8. Logout
	logoutReq, _ := http.NewRequest(http.MethodPost, harness.origin+"/__remote_everything_web_logout", nil)
	logoutResp, err := client.Do(logoutReq)
	if err != nil {
		t.Fatal(err)
	}
	defer logoutResp.Body.Close()
	if logoutResp.StatusCode != http.StatusOK {
		t.Fatalf("logout status = %d; want %d", logoutResp.StatusCode, http.StatusOK)
	}

	// Subsequent /nodes call without session should fail with 401
	afterResp, err := client.Get(harness.origin + "/__remote_everything/nodes")
	if err != nil {
		t.Fatal(err)
	}
	afterResp.Body.Close()
	if afterResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after logout /nodes status = %d; want %d", afterResp.StatusCode, http.StatusUnauthorized)
	}
}

// TestLANWebClient_RequireApprovalFlow verifies that web devices undergo manual approval
// when --require-approval is enabled on the entrance.
func TestLANWebClient_RequireApprovalFlow(t *testing.T) {
	harness := startLANEntrance(t, WithRequireApproval(true))
	client, _ := newWebTestClient(t, harness.pinned)

	// 1. Issue invitation
	var inviteOut bytes.Buffer
	if err := harness.service.trust.RunCLI([]string{"invite", "--name", "Pending Web Browser", "--node", entrancetest.NodeIDs[0], "--ttl", "10m"}, &inviteOut); err != nil {
		t.Fatalf("failed to issue invitation: %v", err)
	}
	var inviteResult struct {
		Invitation string `json:"invitation"`
	}
	if err := json.Unmarshal(inviteOut.Bytes(), &inviteResult); err != nil {
		t.Fatalf("failed to decode invitation: %v", err)
	}

	// 2. Web pair
	pairReqBody, _ := json.Marshal(map[string]string{
		"client_id":   "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
		"device_name": "Pending Web Browser",
	})
	pairReq, _ := http.NewRequest(http.MethodPost, harness.origin+"/__remote_everything_web_pair", bytes.NewReader(pairReqBody))
	pairReq.Header.Set("Authorization", "Invitation "+inviteResult.Invitation)
	pairReq.Header.Set("Content-Type", "application/json")

	pairResp, err := client.Do(pairReq)
	if err != nil {
		t.Fatal(err)
	}
	defer pairResp.Body.Close()

	if pairResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(pairResp.Body)
		t.Fatalf("pair status = %d (body: %s); want 200", pairResp.StatusCode, string(body))
	}

	var pairData struct {
		Status      string `json:"status"`
		Fingerprint string `json:"fingerprint"`
	}
	_ = json.NewDecoder(pairResp.Body).Decode(&pairData)
	if pairData.Status != "pending" {
		t.Fatalf("pair status = %q; want pending", pairData.Status)
	}

	// 3. Activation polling before approval returns 202 Accepted
	activateReq, _ := http.NewRequest(http.MethodPost, harness.origin+"/__remote_everything_web_activate", nil)
	activateResp, err := client.Do(activateReq)
	if err != nil {
		t.Fatal(err)
	}
	activateResp.Body.Close()
	if activateResp.StatusCode != http.StatusAccepted {
		t.Fatalf("activate before approval status = %d; want %d", activateResp.StatusCode, http.StatusAccepted)
	}

	// 4. Accessing /nodes before approval returns 401 Unauthorized
	nodesResp, err := client.Get(harness.origin + "/__remote_everything/nodes")
	if err != nil {
		t.Fatal(err)
	}
	nodesResp.Body.Close()
	if nodesResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("/nodes before approval status = %d; want %d", nodesResp.StatusCode, http.StatusUnauthorized)
	}

	// 5. Operator approves the device
	var approveOut bytes.Buffer
	if err := harness.service.trust.RunCLI([]string{"approve", pairData.Fingerprint}, &approveOut); err != nil {
		t.Fatalf("operator approve failed: %v", err)
	}

	// 6. Activation polling after approval returns 200 OK
	activateReq2, _ := http.NewRequest(http.MethodPost, harness.origin+"/__remote_everything_web_activate", nil)
	activateResp2, err := client.Do(activateReq2)
	if err != nil {
		t.Fatal(err)
	}
	defer activateResp2.Body.Close()
	if activateResp2.StatusCode != http.StatusOK {
		t.Fatalf("activate after approval status = %d; want %d", activateResp2.StatusCode, http.StatusOK)
	}
	var activeData struct {
		Status string `json:"status"`
	}
	_ = json.NewDecoder(activateResp2.Body).Decode(&activeData)
	if activeData.Status != "approved" {
		t.Fatalf("active status = %q; want approved", activeData.Status)
	}

	// 7. Accessing /nodes after approval succeeds
	nodesResp2, err := client.Get(harness.origin + "/__remote_everything/nodes")
	if err != nil {
		t.Fatal(err)
	}
	nodesResp2.Body.Close()
	if nodesResp2.StatusCode != http.StatusOK {
		t.Fatalf("/nodes after approval status = %d; want %d", nodesResp2.StatusCode, http.StatusOK)
	}
}
