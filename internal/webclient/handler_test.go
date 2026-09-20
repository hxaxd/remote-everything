package webclient

import (
	"encoding/json"
	"mime"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

func TestApplicationOpenNegotiation(t *testing.T) {
	for _, tc := range []struct {
		name                            string
		web, authenticated, certificate bool
		wantStatus                      int
	}{
		{"browser session", true, true, false, http.StatusOK},
		{"browser certificate", true, false, true, http.StatusOK},
		{"native redirect", false, true, false, http.StatusFound},
		{"unauthenticated", true, false, false, http.StatusUnauthorized},
	} {
		t.Run(tc.name, func(t *testing.T) {
			manager, err := NewSessionManager(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			fingerprint := strings.Repeat("a", 64)
			session, err := manager.Pair(fingerprint, "Browser", time.Hour)
			if err != nil {
				t.Fatal(err)
			}
			handler := &Handler{sessions: manager}
			next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get(proxysecurity.ClientFingerprintHeader) == "" {
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				if r.Header.Get(proxysecurity.NodeHeader) != "selected-node" {
					t.Error("selected node was lost")
				}
				w.Header().Set("Location", "https://app.example.test/?existing=1")
				w.Header().Set("Cache-Control", "no-store")
				w.WriteHeader(http.StatusFound)
			})
			request := httptest.NewRequest(http.MethodGet, "/__remote_everything/open/editor", nil)
			request.Header.Set(proxysecurity.NodeHeader, "selected-node")
			if tc.web {
				request.Header.Set("Accept", "application/json")
				request.Header.Set("X-Remote-Everything-Web", "1")
			}
			if tc.authenticated {
				request.Header.Set(SessionHeaderName, session.Token)
			}
			if tc.certificate {
				request.Header.Set(proxysecurity.ClientFingerprintHeader, fingerprint)
			}
			recorder := httptest.NewRecorder()
			handler.WithWebSession(next).ServeHTTP(recorder, request)
			if recorder.Code != tc.wantStatus {
				t.Fatalf("status %d, want %d", recorder.Code, tc.wantStatus)
			}
			if tc.wantStatus == http.StatusUnauthorized {
				return
			}
			location := recorder.Header().Get("Location")
			if tc.wantStatus == http.StatusOK {
				if location != "" {
					t.Fatal("JSON response must not redirect")
				}
				var result struct {
					OK       bool   `json:"ok"`
					Location string `json:"location"`
				}
				if err := json.Unmarshal(recorder.Body.Bytes(), &result); err != nil {
					t.Fatal(err)
				}
				if !result.OK {
					t.Fatal("open failed")
				}
				location = result.Location
			}
			if !strings.Contains(recorder.Header().Get("Cache-Control"), "no-store") {
				t.Fatal("ticket response can be cached")
			}
			destination, err := url.Parse(location)
			if err != nil {
				t.Fatal(err)
			}
			if destination.Host != "app.example.test" || destination.Query().Get("existing") != "1" {
				t.Fatal("destination changed")
			}
			ticket := destination.Query().Get(TicketQueryParam)
			if tc.certificate {
				if ticket != "" {
					t.Fatal("certificate access must not create browser credentials")
				}
				return
			}
			if fp, ok := manager.RedeemTicket(ticket); !ok || fp.Fingerprint != fingerprint {
				t.Fatal("missing or invalid handoff ticket")
			}
			if _, ok := manager.RedeemTicket(ticket); ok {
				t.Fatal("handoff ticket was reusable")
			}
		})
	}
}

func TestSVGTypeIndependentOfSystemAssociation(t *testing.T) {
	previous := mime.TypeByExtension(".svg")
	if err := mime.AddExtensionType(".svg", "image/svg"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = mime.AddExtensionType(".svg", previous) })
	m, _ := NewSessionManager(t.TempDir())
	h, _ := NewHandler(nil, m)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/web/icon.svg", nil))
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/svg+xml" || !strings.Contains(rec.Body.String(), "<svg") {
		t.Fatalf("SVG response: %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}
}

func TestHostCookiePrefixPolicy(t *testing.T) {
	h := &Handler{}
	session := Session{Token: strings.Repeat("a", 64), ExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}
	for _, current := range []Session{session, {}} {
		w := httptest.NewRecorder()
		h.setSessionCookie(w, current)
		cookie := w.Result().Cookies()[0]
		if cookie.Name != HostSessionCookieName || cookie.Domain != "" || cookie.Path != "/" || !cookie.Secure || !cookie.HttpOnly {
			t.Fatalf("prefix requirements: %+v", cookie)
		}
		if current.Token == "" && cookie.MaxAge != -1 {
			t.Fatal("logout did not delete prefixed cookie")
		}
	}
	r := httptest.NewRequest("GET", "/", nil)
	r.AddCookie(&http.Cookie{Name: SessionCookieName, Value: "parent-cookie"})
	if h.extractToken(r) != "" {
		t.Fatal("accepted unprefixed cookie")
	}
	r.AddCookie(&http.Cookie{Name: HostSessionCookieName, Value: session.Token})
	if h.extractToken(r) != session.Token {
		t.Fatal("prefixed credential not recognized")
	}
}
