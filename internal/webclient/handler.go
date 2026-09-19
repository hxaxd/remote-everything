package webclient

import (
	"embed"
	"encoding/json"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"strings"

	"github.com/hxaxd/remote-everything/internal/devicecore"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

//go:embed embedded/*
var embeddedFS embed.FS

const (
	webPairPath     = "/__remote_everything_web_pair"
	webActivatePath = "/__remote_everything_web_activate"
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
	Status       string   `json:"status"`
	Nodes        []string `json:"nodes"`
	ExpiresAt    string   `json:"expires_at"`
}

// Handler serves the gateway-hosted web client SPA and handles web pairing/session endpoints.
type Handler struct {
	trust      *devicecore.Trust
	sessions   *SessionManager
	fileServer http.Handler
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

// Sessions returns the underlying SessionManager.
func (h *Handler) Sessions() *SessionManager {
	return h.sessions
}

// IsWebClientRequest reports whether the request is targeting a web client asset or API.
func (h *Handler) IsWebClientRequest(request *http.Request) bool {
	path := request.URL.Path
	if path == "/" || path == "/index.html" || path == "/style.css" || path == "/app.js" ||
		path == "/favicon.ico" || strings.HasPrefix(path, "/web/") ||
		path == webPairPath || path == webActivatePath || path == webLogoutPath {
		return true
	}
	return false
}

// ServeHTTP handles web client static files and web auth endpoints.
func (h *Handler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	path := request.URL.Path

	switch path {
	case webPairPath:
		h.handlePair(writer, request)
		return
	case webActivatePath:
		h.handleActivate(writer, request)
		return
	case webLogoutPath:
		h.handleLogout(writer, request)
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

	session, err := h.sessions.IssueSession(result.Fingerprint, result.DeviceName, DefaultSessionTTL)
	if err != nil {
		gatewaycore.WriteJSON(writer, http.StatusInternalServerError, gatewaycore.Error("session_issue_failed"))
		return
	}

	// 设置 HttpOnly Session Cookie
	http.SetCookie(writer, &http.Cookie{
		Name:     SessionCookieName,
		Value:    session.Token,
		Path:     "/",
		SameSite: http.SameSiteLaxMode,
		Secure:   true,
		HttpOnly: true,
		MaxAge:   int(DefaultSessionTTL.Seconds()),
	})

	gatewaycore.WriteJSON(writer, http.StatusOK, webPairResponse{
		OK:           true,
		DeviceName:   result.DeviceName,
		Fingerprint:  result.Fingerprint,
		SessionToken: session.Token,
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

func (h *Handler) handleLogout(writer http.ResponseWriter, request *http.Request) {
	token := h.extractToken(request)
	if token != "" {
		_ = h.sessions.RevokeSession(token)
	}
	http.SetCookie(writer, &http.Cookie{
		Name:     SessionCookieName,
		Value:    "",
		Path:     "/",
		SameSite: http.SameSiteLaxMode,
		Secure:   true,
		HttpOnly: true,
		MaxAge:   -1,
	})
	gatewaycore.WriteJSON(writer, http.StatusOK, map[string]bool{"ok": true})
}

func (h *Handler) extractToken(request *http.Request) string {
	if cookie, err := request.Cookie(SessionCookieName); err == nil && cookie.Value != "" {
		return cookie.Value
	}
	if header := request.Header.Get(SessionHeaderName); header != "" {
		return header
	}
	return ""
}

// redirectTicketInterceptor intercepts redirects and appends a single-use ticket
// for Web client sessions crossing origins or ports.
type redirectTicketInterceptor struct {
	http.ResponseWriter
	sessions    *SessionManager
	fingerprint string
	wroteHeader bool
}

func (w *redirectTicketInterceptor) WriteHeader(status int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader = true
	if (status == http.StatusFound || status == http.StatusSeeOther || status == http.StatusTemporaryRedirect) && w.fingerprint != "" {
		if loc := w.Header().Get("Location"); loc != "" {
			if u, err := url.Parse(loc); err == nil {
				if ticket, err := w.sessions.IssueTicket(w.fingerprint); err == nil {
					q := u.Query()
					q.Set(TicketQueryParam, ticket)
					u.RawQuery = q.Encode()
					w.Header().Set("Location", u.String())
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

// WithWebSession wraps an existing HTTP handler, converting valid web client sessions
// into internal client fingerprint headers if no mTLS client cert was present.
func (h *Handler) WithWebSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		isWebSession := false
		// If mTLS client certificate was already verified and stamped, keep it
		if request.Header.Get(proxysecurity.ClientFingerprintHeader) == "" {
			// Check for one-time ticket handoff in query parameter
			if ticketStr := request.URL.Query().Get(TicketQueryParam); ticketStr != "" {
				if fp, ok := h.sessions.RedeemTicket(ticketStr); ok {
					// Ticket redeemed: issue a fresh session and set cookie
					if rec, _, err := h.trust.ActivateWebDevice(fp); err == nil && rec.Status == "approved" {
						if session, err := h.sessions.IssueSession(fp, rec.DeviceName, DefaultSessionTTL); err == nil {
							http.SetCookie(writer, &http.Cookie{
								Name:     SessionCookieName,
								Value:    session.Token,
								Path:     "/",
								SameSite: http.SameSiteLaxMode,
								Secure:   true,
								HttpOnly: true,
								MaxAge:   int(DefaultSessionTTL.Seconds()),
							})
							request.Header.Set(proxysecurity.ClientFingerprintHeader, fp)
							isWebSession = true
						}
					}
				}
			}

			// Check session token
			if request.Header.Get(proxysecurity.ClientFingerprintHeader) == "" {
				token := h.extractToken(request)
				if session, ok := h.sessions.ValidateSession(token); ok {
					request.Header.Set(proxysecurity.ClientFingerprintHeader, session.Fingerprint)
					isWebSession = true
				}
			}
		}

		if isWebSession {
			fp := request.Header.Get(proxysecurity.ClientFingerprintHeader)
			writer = &redirectTicketInterceptor{
				ResponseWriter: writer,
				sessions:       h.sessions,
				fingerprint:    fp,
			}
		}

		next.ServeHTTP(writer, request)
	})
}
