package webclient

import (
	"bufio"
	"context"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

//go:embed embedded/*
var embeddedFS embed.FS

const (
	webPairPath     = "/__remote_everything_web_pair"
	webActivatePath = "/__remote_everything_web_activate"
	webLockPath     = "/__remote_everything_web_lock"
	webUnlockPath   = "/__remote_everything_web_unlock"
	webLogoutPath   = "/__remote_everything_web_logout"
	webPairMaxBody  = 8 * 1024
)

type webPairPayload struct {
	DeviceName string `json:"device_name"`
	ClientID   string `json:"client_id"`
}

type webPairResponse struct {
	OK           bool     `json:"ok"`
	DeviceName   string   `json:"device_name"`
	Fingerprint  string   `json:"fingerprint"`
	SessionToken string   `json:"session_token"`
	UnlockToken  string   `json:"unlock_token,omitempty"`
	RevokeToken  string   `json:"revoke_token,omitempty"`
	Status       string   `json:"status"`
	Nodes        []string `json:"nodes"`
	ExpiresAt    string   `json:"expires_at"`
}

// Handler serves the gateway-hosted web client SPA and handles web pairing/session endpoints.
type Handler struct {
	trust            *devicecore.Trust
	sessions         *SessionManager
	fileServer       http.Handler
	hostCookiePrefix bool
}

// NewHandler creates a new webclient Handler.
func NewHandler(trust *devicecore.Trust, sessions *SessionManager) (*Handler, error) {
	sub, err := fs.Sub(embeddedFS, "embedded")
	if err != nil {
		return nil, err
	}
	return &Handler{
		trust:      trust,
		sessions:   sessions,
		fileServer: http.FileServer(http.FS(sub)),
	}, nil
}

// UseHostCookiePrefix binds browser-enforced session cookies to one HTTPS host.
// Select the public entrance's cookie policy before serving requests.
func (h *Handler) UseHostCookiePrefix() { h.hostCookiePrefix = true }
func (h *Handler) sessionCookieName() string {
	if h.hostCookiePrefix {
		return HostSessionCookieName
	}
	return SessionCookieName
}

// Sessions returns the underlying SessionManager.
func (h *Handler) Sessions() *SessionManager {
	return h.sessions
}

// IsWebClientRequest reports whether the request is targeting a web client asset or API.
func (h *Handler) IsWebClientRequest(request *http.Request) bool {
	path := request.URL.Path
	if path == "/" || path == "/index.html" || path == "/style.css" || path == "/app.js" ||
		path == "/favicon.ico" || strings.HasPrefix(path, "/web/") ||
		path == webPairPath || path == webActivatePath || path == webLogoutPath || path == webLockPath || path == webUnlockPath {
		return true
	}
	return false
}

// ServeHTTP handles web client static files and web auth endpoints.
func (h *Handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	path := request.URL.Path
	writer.Header().Set("Cache-Control", "no-store")

	switch path {
	case webPairPath:
		h.handlePair(writer, request)
		return
	case webActivatePath:
		h.handleActivate(writer, request)
		return
	case webLogoutPath:
		h.handleRevoke(writer, request, true)
		return
	case webLockPath:
		h.handleRevoke(writer, request, false)
		return
	case webUnlockPath:
		h.handleUnlock(writer, request)
		return
	case "/favicon.ico":
		writer.WriteHeader(http.StatusNoContent)
		return
	}

	if path == "/" || path == "/index.html" {
		indexBytes, err := embeddedFS.ReadFile("embedded/index.html")
		if err == nil {
			writer.Header().Set("Content-Type", "text/html; charset=utf-8")
			writer.Header().Set("Cache-Control", "no-cache")
			writer.WriteHeader(http.StatusOK)
			_, _ = writer.Write(indexBytes)
			return
		}
	}

	// 静态资源服务
	if strings.HasPrefix(path, "/web/") {
		request = request.Clone(request.Context())
		request.URL.Path = strings.TrimPrefix(path, "/web")
		if request.URL.Path == "" {
			request.URL.Path = "/"
		}
	}
	writer.Header().Set("Cache-Control", "no-cache")
	// Windows registry MIME associations must not determine embedded asset types.
	if strings.HasSuffix(request.URL.Path, ".svg") {
		writer.Header().Set("Content-Type", "image/svg+xml")
	}
	h.fileServer.ServeHTTP(writer, request)
}

func (h *Handler) handlePair(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		gatewaycore.WriteJSON(writer, http.StatusMethodNotAllowed, gatewaycore.Error("method_not_allowed"))
		return
	}
	invitation := strings.TrimSpace(request.Header.Get("Authorization"))
	if strings.HasPrefix(invitation, "Invitation ") {
		invitation = strings.TrimSpace(strings.TrimPrefix(invitation, "Invitation "))
	}
	if invitation == "" {
		invitation = strings.TrimSpace(request.URL.Query().Get("invitation"))
	}
	if request.ContentLength <= 0 || request.ContentLength > webPairMaxBody {
		gatewaycore.WriteJSON(writer, http.StatusBadRequest, gatewaycore.Error("invalid_body"))
		return
	}
	decoder := json.NewDecoder(io.LimitReader(request.Body, webPairMaxBody))
	decoder.DisallowUnknownFields()
	var payload webPairPayload
	if decoder.Decode(&payload) != nil || decoder.Decode(&struct{}{}) != io.EOF {
		gatewaycore.WriteJSON(writer, http.StatusBadRequest, gatewaycore.Error("invalid_json"))
		return
	}
	// The pairing itself is the trust's: the address the request came from goes
	// with it, and the limits, the delay before a refusal and the admission all
	// belong to the same door as every other pairing.
	result, code, err := h.trust.PairWebDevice(devicecore.ClientAddress(request), invitation, payload.ClientID, payload.DeviceName)
	if err != nil {
		status := http.StatusBadRequest
		switch code {
		case "invitation_denied":
			status = http.StatusUnauthorized
		case "rate_limited":
			status = http.StatusTooManyRequests
		case "server_busy":
			status = http.StatusServiceUnavailable
		case "pairing_failed":
			status = http.StatusInternalServerError
		}
		gatewaycore.WriteJSON(writer, status, gatewaycore.Error(code))
		return
	}

	session, err := h.sessions.Pair(result.Fingerprint, result.DeviceName, DefaultSessionTTL)
	if err != nil {
		gatewaycore.WriteJSON(writer, http.StatusInternalServerError, gatewaycore.Error("session_issue_failed"))
		return
	}

	h.setSessionCookie(writer, session.Session)

	gatewaycore.WriteJSON(writer, http.StatusOK, webPairResponse{
		OK:           true,
		DeviceName:   result.DeviceName,
		Fingerprint:  result.Fingerprint,
		SessionToken: session.Token,
		UnlockToken:  session.UnlockToken,
		RevokeToken:  session.RevokeToken,
		Status:       result.Status,
		Nodes:        result.Nodes,
		ExpiresAt:    session.ExpiresAt,
	})
}

func (h *Handler) handleActivate(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		gatewaycore.WriteJSON(writer, http.StatusMethodNotAllowed, gatewaycore.Error("method_not_allowed"))
		return
	}
	token := h.extractToken(request)
	session, ok := h.sessions.ValidateSession(token)
	if !ok {
		gatewaycore.WriteJSON(writer, http.StatusUnauthorized, gatewaycore.Error("unauthorized"))
		return
	}

	state, code, err := h.trust.ActivateWebDevice(session.Fingerprint)
	if err != nil {
		status := http.StatusUnauthorized
		if code == "approval_pending" {
			status = http.StatusAccepted
		}
		gatewaycore.WriteJSON(writer, status, gatewaycore.Error(code))
		return
	}

	gatewaycore.WriteJSON(writer, http.StatusOK, map[string]any{
		"ok":          true,
		"device_name": state.DeviceName,
		"fingerprint": state.Fingerprint,
		"status":      state.Status,
		"nodes":       state.Nodes,
	})
}

func (h *Handler) setSessionCookie(w http.ResponseWriter, s Session) {
	expiry, _ := time.Parse(time.RFC3339Nano, s.ExpiresAt)
	maxAge := int(time.Until(expiry).Seconds())
	if maxAge < 1 {
		maxAge = 1
	}
	if s.Token == "" {
		maxAge = -1
	}
	http.SetCookie(w, &http.Cookie{Name: h.sessionCookieName(), Value: s.Token, Path: "/", SameSite: http.SameSiteLaxMode, Secure: true, HttpOnly: true, MaxAge: maxAge})
}
func (h *Handler) handleRevoke(w http.ResponseWriter, r *http.Request, logout bool) {
	if r.Method != http.MethodPost {
		gatewaycore.WriteJSON(w, 405, gatewaycore.Error("method_not_allowed"))
		return
	}
	// A cookie or an access token cannot unlock a connection or manage its lifetime.
	credential := r.Header.Get(RevokeHeaderName)
	if !validHex64.MatchString(credential) {
		gatewaycore.WriteJSON(w, 401, gatewaycore.Error("unauthorized"))
		return
	}
	if err := h.sessions.Revoke(credential, logout); err != nil {
		gatewaycore.WriteJSON(w, 500, gatewaycore.Error("session_revoke_failed"))
		return
	}
	h.setSessionCookie(w, Session{})
	gatewaycore.WriteJSON(w, 200, map[string]bool{"ok": true})
}
func (h *Handler) handleUnlock(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		gatewaycore.WriteJSON(w, 405, gatewaycore.Error("method_not_allowed"))
		return
	}
	s, err := h.sessions.Unlock(r.Header.Get(UnlockHeaderName))
	if err != nil {
		status, code := 500, "session_issue_failed"
		if errors.Is(err, ErrUnauthorized) {
			status, code = 401, "connection_expired"
		}
		gatewaycore.WriteJSON(w, status, gatewaycore.Error(code))
		return
	}
	result, code, err := h.trust.ActivateWebDevice(s.Fingerprint)
	if err != nil && code != "approval_pending" {
		_ = h.sessions.RevokeFingerprint(s.Fingerprint)
		gatewaycore.WriteJSON(w, 401, gatewaycore.Error("connection_expired"))
		return
	}
	status := result.Status
	if code == "approval_pending" {
		status = "pending"
	}
	h.setSessionCookie(w, s)
	gatewaycore.WriteJSON(w, 200, webPairResponse{OK: true, DeviceName: s.DeviceName, Fingerprint: s.Fingerprint, SessionToken: s.Token, Status: status, ExpiresAt: s.ExpiresAt})
}
func (h *Handler) extractToken(r *http.Request) string {
	// Explicit credentials take priority over cookies shared across LAN ports.
	if header := r.Header.Get(SessionHeaderName); header != "" {
		return header
	}
	if cookie, err := r.Cookie(h.sessionCookieName()); err == nil {
		return cookie.Value
	}
	return ""
}

// redirectTicketInterceptor intercepts redirects and appends a single-use ticket
// for Web client sessions crossing origins or ports.
type redirectTicketInterceptor struct {
	http.ResponseWriter
	sessions     *SessionManager
	token        string
	wroteHeader  bool
	jsonRedirect bool
}

func (w *redirectTicketInterceptor) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader = true
	if status == http.StatusFound || status == http.StatusSeeOther || status == http.StatusTemporaryRedirect {
		if loc := w.Header().Get("Location"); loc != "" {
			if u, err := url.Parse(loc); err == nil {
				if w.token != "" {
					ticket, err := w.sessions.IssueTicket(w.token)
					if err != nil {
						w.Header().Del("Location")
						gatewaycore.WriteJSON(w.ResponseWriter, 401, gatewaycore.Error("unauthorized"))
						return
					}
					q := u.Query()
					q.Set(TicketQueryParam, ticket)
					u.RawQuery = q.Encode()
				}
				w.Header().Set("Cache-Control", "no-store")
				w.Header().Set("Location", u.String())
				if w.jsonRedirect {
					w.Header().Del("Location")
					gatewaycore.WriteJSON(w.ResponseWriter, 200, map[string]any{"ok": true, "location": u.String()})
					return
				}
			}
		}
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *redirectTicketInterceptor) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(b)
}

func (w *redirectTicketInterceptor) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func (w *redirectTicketInterceptor) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// sessionWriter closes hijacked connections when the access session is revoked
// or expires. Request cancellation alone does not guarantee a WebSocket closes.
type sessionWriter struct {
	http.ResponseWriter
	ctx context.Context
}

func (w *sessionWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *sessionWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	conn, rw, err := http.NewResponseController(w.ResponseWriter).Hijack()
	if err != nil {
		return nil, nil, err
	}
	stop := context.AfterFunc(w.ctx, func() { _ = conn.Close() })
	return &sessionConn{Conn: conn, stop: stop}, rw, nil
}

type sessionConn struct {
	net.Conn
	stop func() bool
}

func (c *sessionConn) Close() error { c.stop(); return c.Conn.Close() }

// WithWebSession grants access and tracks every authorized request for revocation.
func (h *Handler) WithWebSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := ""
		handoff := false
		if r.Header.Get(proxysecurity.ClientFingerprintHeader) == "" {
			token = h.extractToken(r)
			if ticket := r.URL.Query().Get(TicketQueryParam); ticket != "" {
				s, ok := h.sessions.RedeemTicket(ticket)
				if !ok {
					gatewaycore.WriteJSON(w, 401, gatewaycore.Error("unauthorized"))
					return
				}
				token = s.Token
				handoff = true
				h.setSessionCookie(w, s)
				// Remove the consumed ticket before serving the application.
				q := r.URL.Query()
				q.Del(TicketQueryParam)
				r.URL.RawQuery = q.Encode()
			}
			s, ctx, done, ok := h.sessions.Acquire(r.Context(), token)
			if ok {
				defer done()
				r = r.WithContext(ctx)
				r.Header.Set(proxysecurity.ClientFingerprintHeader, s.Fingerprint)
				w = &sessionWriter{ResponseWriter: w, ctx: ctx}
				if handoff {
					w.Header().Set("Cache-Control", "no-store")
					w.Header().Set("Referrer-Policy", "no-referrer")
					destination := *r.URL
					destination.Scheme = ""
					destination.Host = ""
					destination.User = nil
					// Relative redirects must not be interpreted as a new host.
					if strings.HasPrefix(destination.Path, "//") {
						destination.Path = "/"
					}
					w.Header().Set("Location", destination.String())
					w.WriteHeader(http.StatusSeeOther)
					return
				}
			} else {
				token = ""
			}
		}
		jsonRedirect := strings.HasPrefix(r.URL.Path, "/__remote_everything/open/") && r.Header.Get("X-Remote-Everything-Web") == "1" && r.Header.Get("Accept") == "application/json"
		if strings.HasPrefix(r.URL.Path, "/__remote_everything/open/") && (token != "" || (jsonRedirect && r.Header.Get(proxysecurity.ClientFingerprintHeader) != "")) {
			w = &redirectTicketInterceptor{ResponseWriter: w, sessions: h.sessions, token: token, jsonRedirect: jsonRedirect}
		}
		next.ServeHTTP(w, r)
	})
}
