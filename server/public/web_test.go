package main

import (
	"bytes"
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

func newPublicWebTestClient(t *testing.T) (*http.Client, *cookiejar.Jar) {
	t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{
		Jar: jar,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Timeout: 5 * time.Second,
	}
	return client, jar
}

// TestPublicWebClient_StaticAssets verifies the embedded SPA static assets are correctly served by public gateway.
func TestPublicWebClient_StaticAssets(t *testing.T) {
	harness := startPublicEntrance(t)
	client, _ := newPublicWebTestClient(t)

	tests := []struct {
		path        string
		wantStatus  int
		wantContent string
	}{
		{"/", http.StatusOK, "<title>Remote Everything</title>"},
		{"/index.html", http.StatusOK, "id=\"view-pair\""},
		{"/style.css", http.StatusOK, "--canvas"},
		{"/app.js", http.StatusOK, "CryptoVault"},
		{"/favicon.ico", http.StatusNoContent, ""},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodGet, harness.status+tt.path, nil)
			if err != nil {
				t.Fatal(err)
			}
			req.Host = harness.host
			resp, err := client.Do(req)
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

// TestPublicWebClient_EndToEndFlow verifies the full Web client lifecycle on public gateway:
// pairing -> approve -> nodes query -> apps query -> logout.
func TestPublicWebClient_EndToEndFlow(t *testing.T) {
	harness := startPublicEntrance(t)
	client, _ := newPublicWebTestClient(t)

	// 1. Unauthenticated request to /nodes should return 401
	unauthReq, _ := http.NewRequest(http.MethodGet, harness.status+"/__remote_everything/nodes", nil)
	unauthReq.Host = harness.host
	resp, err := client.Do(unauthReq)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /nodes status = %d; want %d", resp.StatusCode, http.StatusUnauthorized)
	}

	// 2. Issue invitation on public gateway
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
		"client_id":   "b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
		"device_name": "Test Web Browser",
	})
	pairReq, err := http.NewRequest(http.MethodPost, harness.status+"/__remote_everything_web_pair", bytes.NewReader(pairReqBody))
	if err != nil {
		t.Fatal(err)
	}
	pairReq.Host = harness.host
	pairReq.Header.Set("Authorization", "Invitation "+inviteResult.Invitation)
	pairReq.Header.Set("Content-Type", "application/json")

	pairResp, err := client.Do(pairReq)
	if err != nil {
		t.Fatalf("pair request failed: %v", err)
	}
	defer pairResp.Body.Close()

	if pairResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(pairResp.Body)
		t.Fatalf("pair request status = %d (body: %s); want 200 OK", pairResp.StatusCode, string(body))
	}

	var pairData struct {
		OK           bool     `json:"ok"`
		DeviceName   string   `json:"device_name"`
		Fingerprint  string   `json:"fingerprint"`
		SessionToken string   `json:"session_token"`
		RevokeToken  string   `json:"revoke_token"`
		UnlockToken  string   `json:"unlock_token"`
		Status       string   `json:"status"`
		Nodes        []string `json:"nodes"`
	}
	if err := json.NewDecoder(pairResp.Body).Decode(&pairData); err != nil {
		t.Fatalf("failed to decode pair response: %v", err)
	}
	if !pairData.OK || pairData.Status != "pending" || pairData.Fingerprint == "" {
		t.Fatalf("unexpected pair result: %+v", pairData)
	}

	// 4. Admin approves the pending device
	var approveOut bytes.Buffer
	if err := harness.service.trust.RunCLI([]string{"approve", pairData.Fingerprint}, &approveOut); err != nil {
		t.Fatalf("failed to approve device: %v", err)
	}

	// 5. Activate the web session
	actReq, _ := http.NewRequest(http.MethodPost, harness.status+"/__remote_everything_web_activate", nil)
	actReq.Host = harness.host
	actReq.Header.Set("X-Remote-Everything-Web-Token", pairData.SessionToken)
	actResp, err := client.Do(actReq)
	if err != nil {
		t.Fatalf("activate request failed: %v", err)
	}
	defer actResp.Body.Close()
	if actResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(actResp.Body)
		t.Fatalf("activate status = %d (body: %s); want %d", actResp.StatusCode, string(body), http.StatusOK)
	}

	// 6. Query /__remote_everything/nodes with web session
	nodesReq, _ := http.NewRequest(http.MethodGet, harness.status+"/__remote_everything/nodes", nil)
	nodesReq.Host = harness.host
	nodesReq.Header.Set("X-Remote-Everything-Web-Token", pairData.SessionToken)
	nodesResp, err := client.Do(nodesReq)
	if err != nil {
		t.Fatalf("query /nodes failed: %v", err)
	}
	defer nodesResp.Body.Close()
	if nodesResp.StatusCode != http.StatusOK {
		t.Fatalf("/nodes status = %d; want %d", nodesResp.StatusCode, http.StatusOK)
	}

	var nodesData struct {
		OK    bool `json:"ok"`
		Nodes []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"nodes"`
	}
	if err := json.NewDecoder(nodesResp.Body).Decode(&nodesData); err != nil {
		t.Fatalf("failed to decode nodes response: %v", err)
	}
	if !nodesData.OK || len(nodesData.Nodes) != 1 || nodesData.Nodes[0].ID != entrancetest.NodeIDs[0] {
		t.Fatalf("unexpected nodes list: %+v", nodesData)
	}

	// 7. Query /__remote_everything/apps for the granted node
	appsReq, _ := http.NewRequest(http.MethodGet, harness.status+"/__remote_everything/apps", nil)
	appsReq.Host = harness.host
	appsReq.Header.Set(proxysecurity.NodeHeader, entrancetest.NodeIDs[0])
	appsReq.Header.Set("X-Remote-Everything-Web-Token", pairData.SessionToken)
	appsResp, err := client.Do(appsReq)
	if err != nil {
		t.Fatalf("query /apps failed: %v", err)
	}
	defer appsResp.Body.Close()
	if appsResp.StatusCode != http.StatusOK {
		t.Fatalf("/apps status = %d; want %d", appsResp.StatusCode, http.StatusOK)
	}

	// The application origin receives its own cookie via the one-use handoff.
	openReq, _ := http.NewRequest(http.MethodGet, harness.status+"/__remote_everything/open/editor", nil)
	openReq.Host = harness.host
	openReq.Header.Set(webclient.SessionHeaderName, pairData.SessionToken)
	openReq.Header.Set(proxysecurity.NodeHeader, entrancetest.NodeIDs[0])
	opened, err := client.Do(openReq)
	if err != nil {
		t.Fatal(err)
	}
	opened.Body.Close()
	if opened.StatusCode != 302 {
		t.Fatalf("open: %d", opened.StatusCode)
	}
	destination, err := url.Parse(opened.Header.Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	handoff, _ := http.NewRequest(http.MethodGet, harness.status+destination.RequestURI(), nil)
	handoff.Host = destination.Host
	handed, err := client.Do(handoff)
	if err != nil {
		t.Fatal(err)
	}
	handed.Body.Close()
	if handed.StatusCode != 303 || strings.Contains(handed.Header.Get("Location"), "_reticket") {
		t.Fatal("handoff did not clean URL")
	}
	appCookie := ""
	for _, cookie := range handed.Cookies() {
		if cookie.Name == webclient.HostSessionCookieName {
			appCookie = cookie.Value
		}
	}
	if appCookie == "" {
		t.Fatal("no application session")
	}
	checkApp := func(token string, want int) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, harness.status+"/", nil)
		req.Host = destination.Host
		req.AddCookie(&http.Cookie{Name: webclient.HostSessionCookieName, Value: token})
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("app: %d, want %d", resp.StatusCode, want)
		}
	}
	checkApp(appCookie, 200)
	policyReq, _ := http.NewRequest(http.MethodGet, harness.status+"/cookie-policy", nil)
	policyReq.Host = destination.Host
	policyReq.AddCookie(&http.Cookie{Name: webclient.HostSessionCookieName, Value: appCookie})
	policyResp, err := client.Do(policyReq)
	if err != nil {
		t.Fatal(err)
	}
	policyResp.Body.Close()
	if policyResp.StatusCode != 200 {
		t.Fatalf("policy proxy: %d", policyResp.StatusCode)
	}
	appCookies := policyResp.Cookies()
	if len(appCookies) != 1 || appCookies[0].Name != "session" || appCookies[0].Value != "value" || appCookies[0].Domain != "" || !appCookies[0].Secure || !appCookies[0].HttpOnly {
		t.Fatalf("public cookie boundary: %v", policyResp.Header.Values("Set-Cookie"))
	}
	// An unprefixed cookie can be written at a parent domain. It must not
	// authorize this entrance, even if its value happens to be a valid token.
	spoofReq, _ := http.NewRequest(http.MethodGet, harness.status+"/", nil)
	spoofReq.Host = destination.Host
	spoofReq.AddCookie(&http.Cookie{Name: webclient.SessionCookieName, Value: appCookie})
	spoofResp, err := client.Do(spoofReq)
	if err != nil {
		t.Fatal(err)
	}
	spoofResp.Body.Close()
	if spoofResp.StatusCode != 401 {
		t.Fatal("unprefixed cookie authorized public access")
	}

	// Management credentials are separate; cookies cannot unlock the connection.
	check := func(path, header, credential string, want int) []byte {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, harness.status+path, nil)
		req.Host = harness.host
		if header != "" {
			req.Header.Set(header, credential)
		}
		response, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		body, _ := io.ReadAll(response.Body)
		if response.StatusCode != want {
			t.Fatalf("%s status %d, want %d: %s", path, response.StatusCode, want, body)
		}
		return body
	}
	check("/__remote_everything_web_unlock", webclient.UnlockHeaderName, pairData.SessionToken, 401)
	check("/__remote_everything_web_lock", "", "", 401)
	check("/__remote_everything_web_lock", webclient.RevokeHeaderName, pairData.RevokeToken, 200)
	checkApp(appCookie, 401)
	check("/__remote_everything_web_activate", webclient.SessionHeaderName, pairData.SessionToken, 401)
	body := check("/__remote_everything_web_unlock", webclient.UnlockHeaderName, pairData.UnlockToken, 200)
	var unlocked struct {
		Token string `json:"session_token"`
	}
	if err := json.Unmarshal(body, &unlocked); err != nil {
		t.Fatal(err)
	}
	if unlocked.Token == "" || unlocked.Token == pairData.SessionToken {
		t.Fatal("unlock must replace access token")
	}
	check("/__remote_everything_web_activate", webclient.SessionHeaderName, unlocked.Token, 200)
	check("/__remote_everything_web_activate", webclient.SessionHeaderName, pairData.SessionToken, 401)
	pairData.SessionToken = unlocked.Token
	checkApp(appCookie, 401)
	checkApp(unlocked.Token, 200)

	// 8. Logout
	logoutReq, _ := http.NewRequest(http.MethodPost, harness.status+"/__remote_everything_web_logout", nil)
	logoutReq.Host = harness.host
	logoutReq.Header.Set("X-Remote-Everything-Web-Token", pairData.SessionToken)
	logoutReq.Header.Set(webclient.RevokeHeaderName, pairData.RevokeToken)
	logoutResp, err := client.Do(logoutReq)
	if err != nil {
		t.Fatalf("logout failed: %v", err)
	}
	defer logoutResp.Body.Close()
	if logoutResp.StatusCode != http.StatusOK {
		t.Fatalf("logout status = %d; want %d", logoutResp.StatusCode, http.StatusOK)
	}

	check("/__remote_everything_web_unlock", webclient.UnlockHeaderName, pairData.UnlockToken, 401)

	checkApp(unlocked.Token, 401)

	// 9. Query /nodes after logout should be 401
	afterReq, _ := http.NewRequest(http.MethodGet, harness.status+"/__remote_everything/nodes", nil)
	afterReq.Host = harness.host
	afterReq.Header.Set("X-Remote-Everything-Web-Token", pairData.SessionToken)
	afterResp, err := client.Do(afterReq)
	if err != nil {
		t.Fatalf("post-logout /nodes failed: %v", err)
	}
	defer afterResp.Body.Close()
	if afterResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after logout /nodes status = %d; want 401", afterResp.StatusCode)
	}
}
