package webclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestSessionManager_Lifecycle(t *testing.T) {
	root := t.TempDir()
	mgr, err := NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}

	fp := strings.Repeat("1", 64)
	session, err := mgr.IssueSession(fp, "Test Chrome", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if session.Fingerprint != fp || session.DeviceName != "Test Chrome" || len(session.Token) != 64 {
		t.Fatalf("unexpected session: %+v", session)
	}

	// Validate
	got, ok := mgr.ValidateSession(session.Token)
	if !ok || got.Fingerprint != fp {
		t.Fatalf("expected valid session, got: %+v, ok=%v", got, ok)
	}

	// Persistence across reload
	mgr2, err := NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}
	got2, ok := mgr2.ValidateSession(session.Token)
	if !ok || got2.Fingerprint != fp {
		t.Fatalf("expected reloaded valid session, got: %+v, ok=%v", got2, ok)
	}

	// Ticket
	ticket, err := mgr2.IssueTicket(fp)
	if err != nil {
		t.Fatal(err)
	}
	redeemedFp, ok := mgr2.RedeemTicket(ticket)
	if !ok || redeemedFp != fp {
		t.Fatalf("expected redeemed ticket fp=%q, got=%q, ok=%v", fp, redeemedFp, ok)
	}
	// Ticket must be single use
	if _, ok := mgr2.RedeemTicket(ticket); ok {
		t.Fatal("ticket was redeemed twice")
	}

	// Revoke
	if err := mgr2.RevokeSession(session.Token); err != nil {
		t.Fatal(err)
	}
	if _, ok := mgr2.ValidateSession(session.Token); ok {
		t.Fatal("session should be revoked")
	}

	// Re-issue and RevokeFingerprint
	s2, err := mgr2.IssueSession(fp, "Test Firefox", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if err := mgr2.RevokeFingerprint(fp); err != nil {
		t.Fatal(err)
	}
	if _, ok := mgr2.ValidateSession(s2.Token); ok {
		t.Fatal("session should be revoked by fingerprint")
	}
}

func TestWebHandler_StaticAndSessionMiddleware(t *testing.T) {
	root := t.TempDir()
	mgr, err := NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewHandler(nil, mgr)
	if err != nil {
		t.Fatal(err)
	}

	// 1. Static asset: GET /
	req := httptest.NewRequest("GET", "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Remote Everything") {
		t.Fatalf("expected 200 OK with html, got: %d %s", rec.Code, rec.Body.String())
	}

	// 2. Static asset: GET /web/style.css
	reqCss := httptest.NewRequest("GET", "/web/style.css", nil)
	recCss := httptest.NewRecorder()
	handler.ServeHTTP(recCss, reqCss)
	if recCss.Code != http.StatusOK || !strings.Contains(recCss.Body.String(), "--bg-main") {
		t.Fatalf("expected 200 OK for css, got: %d", recCss.Code)
	}

	// 3. Static asset: GET /web/app.js
	reqJs := httptest.NewRequest("GET", "/web/app.js", nil)
	recJs := httptest.NewRecorder()
	handler.ServeHTTP(recJs, reqJs)
	if recJs.Code != http.StatusOK || !strings.Contains(recJs.Body.String(), "CryptoVault") {
		t.Fatalf("expected 200 OK for js, got: %d", recJs.Code)
	}

	// 4. Test WithWebSession Middleware
	fp := strings.Repeat("2", 64)
	session, err := mgr.IssueSession(fp, "Test Browser", time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	var capturedFingerprint string
	nextHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedFingerprint = r.Header.Get("X-Remote-Everything-Client-Fingerprint")
		w.WriteHeader(http.StatusOK)
	})

	wrapped := handler.WithWebSession(nextHandler)

	// Case A: With Cookie
	reqAuth := httptest.NewRequest("GET", "/__remote_everything/apps", nil)
	reqAuth.AddCookie(&http.Cookie{Name: SessionCookieName, Value: session.Token})
	recAuth := httptest.NewRecorder()
	wrapped.ServeHTTP(recAuth, reqAuth)
	if capturedFingerprint != fp {
		t.Fatalf("expected injected fingerprint %q, got %q", fp, capturedFingerprint)
	}

	// Case B: With Header
	capturedFingerprint = ""
	reqHeader := httptest.NewRequest("GET", "/__remote_everything/apps", nil)
	reqHeader.Header.Set(SessionHeaderName, session.Token)
	recHeader := httptest.NewRecorder()
	wrapped.ServeHTTP(recHeader, reqHeader)
	if capturedFingerprint != fp {
		t.Fatalf("expected injected fingerprint %q via header, got %q", fp, capturedFingerprint)
	}
}
