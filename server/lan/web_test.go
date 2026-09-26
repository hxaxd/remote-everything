package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/backplane/proxysecurity"
)

// This entrance serves no web client, and that is a decision rather than a gap: its
// applications are served on ports of the entrance's own host, and a browser keeps
// cookies by host and not by port, so a browser session here would share one cookie
// jar with every application it can open — an application's page could write cookies
// this entrance receives, and read every cookie of it that is not HttpOnly. A
// browser is not a client of this shape; a device holding a certificate is.
//
// What is pinned here is that it stays that way: the web client's own paths answer
// the trust's refusal, no session cookie is ever handed out, and a cookie admits
// nothing. The trade itself is written down in `skills/remote-everything-app`.

// browserClient is a browser seen from this entrance: it trusts the certificate the
// entrance pinned, keeps no cookie jar, and reads a redirect as the answer rather
// than following it. What a browser is refused does not depend on it remembering
// anything.
func browserClient(t *testing.T, pinned *x509.Certificate) *http.Client {
	t.Helper()
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: x509.NewCertPool()}
	tlsConfig.RootCAs.AddCert(pinned)
	return &http.Client{
		Transport:     &http.Transport{TLSClientConfig: tlsConfig},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Timeout:       5 * time.Second,
	}
}

// refused is the answer an entrance gives a request that is not a device's: the
// trust's own refusal, which is a body a client reads rather than a page a browser
// renders.
func refused(t *testing.T, response *http.Response, body []byte) {
	t.Helper()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d (body: %s); want %d", response.StatusCode, body, http.StatusUnauthorized)
	}
	if contentType := response.Header.Get("Content-Type"); !strings.HasPrefix(contentType, "application/json") {
		t.Fatalf("Content-Type = %q; want a refusal rather than a page", contentType)
	}
	var refusal struct {
		OK   bool   `json:"ok"`
		Code string `json:"code"`
	}
	if json.Unmarshal(body, &refusal) != nil || refusal.Code != "unauthorized" {
		t.Fatalf("body = %q; want the unauthorized refusal", body)
	}
}

// TestLANEntranceServesNoWebClient asks for the web client where it would be: the
// page itself, the assets it loads, and the same assets under the path the public
// entrance serves them at.
func TestLANEntranceServesNoWebClient(t *testing.T) {
	harness := startLANEntrance(t)
	client := browserClient(t, harness.pinned)
	paths := []string{"/", "/index.html", "/style.css", "/app.js", "/favicon.ico", "/web/", "/web/app.js", "/web/icon.svg"}
	for _, path := range paths {
		response, err := client.Get(harness.origin + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("GET %s status = %d (body: %s); want %d", path, response.StatusCode, body, http.StatusUnauthorized)
		}
		if len(response.Cookies()) != 0 {
			t.Fatalf("GET %s handed out a cookie: %+v", path, response.Cookies())
		}
		if strings.Contains(string(body), "<!DOCTYPE") || strings.Contains(string(body), "Remote Everything") {
			t.Fatalf("GET %s served a page: %s", path, body)
		}
	}
}

// TestLANEntranceRefusesWebPairing pairs, activates and ends a web session where the
// web client would: a browser cannot become a device of this shape, whatever the
// invitation it holds.
func TestLANEntranceRefusesWebPairing(t *testing.T) {
	harness := startLANEntrance(t)
	client := browserClient(t, harness.pinned)
	paths := []string{
		"/__remote_everything_web_pair",
		"/__remote_everything_web_activate",
		"/__remote_everything_web_unlock",
		"/__remote_everything_web_lock",
		"/__remote_everything_web_logout",
	}
	for _, path := range paths {
		response, err := client.Post(harness.origin+path, "application/json", strings.NewReader(`{"client_id":"a1b2c3","device_name":"Browser"}`))
		if err != nil {
			t.Fatalf("POST %s: %v", path, err)
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		refused(t, response, body)
	}
}

// TestLANEntranceDoesNotAdmitAWebCookie presents the session cookie itself — both the
// name the public entrance issues and the un-prefixed one this deployment owns — on a
// request that would be authorized if a cookie were a credential here.
func TestLANEntranceDoesNotAdmitAWebCookie(t *testing.T) {
	harness := startLANEntrance(t)
	client := browserClient(t, harness.pinned)
	names := []string{proxysecurity.HostWebSessionCookieName, proxysecurity.WebSessionCookieName}
	for _, name := range names {
		request, err := http.NewRequest(http.MethodGet, harness.origin+"/__remote_everything/nodes", nil)
		if err != nil {
			t.Fatal(err)
		}
		request.AddCookie(&http.Cookie{Name: name, Value: strings.Repeat("a", 64)})
		response, err := client.Do(request)
		if err != nil {
			t.Fatalf("GET /__remote_everything/nodes with %s: %v", name, err)
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		refused(t, response, body)
	}
}
