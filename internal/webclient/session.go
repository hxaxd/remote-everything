package webclient

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/secret"
)

const (
	// SessionCookieName is the cookie carrying the web client session token.
	// Its name is the deployment's own, named once in proxysecurity with the
	// other names an application never sees, because a session is how the
	// gateway knows who the browser is and not something an application owns.
	SessionCookieName = proxysecurity.WebSessionCookieName
	// SessionHeaderName is the alternative HTTP header carrying the web client session token.
	SessionHeaderName = "X-Remote-Everything-Web-Token"
	// TicketQueryParam is the URL query parameter carrying the one-time authorization ticket.
	TicketQueryParam = "_reticket"
	// DefaultSessionTTL is the default lifetime for a web client session.
	DefaultSessionTTL = 30 * 24 * time.Hour
	// DefaultTicketTTL is the lifetime for a one-time application origin ticket.
	DefaultTicketTTL = 1 * time.Minute
	sessionsFileName = "web-sessions.json"
)

var validHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

// Session describes an active browser web client session.
type Session struct {
	Token       string `json:"token"`
	Fingerprint string `json:"fingerprint"`
	DeviceName  string `json:"device_name"`
	CreatedAt   string `json:"created_at"`
	ExpiresAt   string `json:"expires_at"`
}

type ticketRecord struct {
	fingerprint string
	expiresAt   time.Time
}

type sessionStore struct {
	Sessions []Session `json:"sessions"`
}

// SessionManager manages web client sessions and short-lived tickets for application access.
type SessionManager struct {
	root     string
	mu       sync.RWMutex
	sessions map[string]Session // token -> Session
	tickets  map[string]ticketRecord
}

// NewSessionManager opens or initializes the web session manager for a gateway state root.
// Sessions that ran out are left out of the manager, and the store is rewritten without
// them: a store that only ever grows is one no sweep ever saved.
func NewSessionManager(root string) (*SessionManager, error) {
	if root == "" || !filepath.IsAbs(root) {
		return nil, errors.New("state root must be absolute")
	}
	manager := &SessionManager{
		root:     filepath.Clean(root),
		sessions: make(map[string]Session),
		tickets:  make(map[string]ticketRecord),
	}
	filePath := filepath.Join(manager.root, sessionsFileName)
	var store sessionStore
	pruned := false
	if err := jsonfile.Read(filePath, &store); err == nil {
		now := time.Now().UTC()
		for _, s := range store.Sessions {
			if exp, err := time.Parse(time.RFC3339, s.ExpiresAt); err == nil && now.Before(exp) {
				manager.sessions[s.Token] = s
			} else {
				pruned = true
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if pruned {
		if err := manager.saveLocked(); err != nil {
			return nil, err
		}
	}
	return manager, nil
}

func (m *SessionManager) saveLocked() error {
	list := make([]Session, 0, len(m.sessions))
	now := time.Now().UTC()
	for _, s := range m.sessions {
		if exp, err := time.Parse(time.RFC3339, s.ExpiresAt); err == nil && now.Before(exp) {
			list = append(list, s)
		}
	}
	return jsonfile.Write(filepath.Join(m.root, sessionsFileName), sessionStore{Sessions: list}, 0o600)
}

// IssueSession mints a new web session token bound to a device fingerprint.
func (m *SessionManager) IssueSession(fingerprint, deviceName string, ttl time.Duration) (Session, error) {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	if !validHex64.MatchString(fingerprint) {
		return Session{}, errors.New("invalid device fingerprint")
	}
	if ttl <= 0 {
		ttl = DefaultSessionTTL
	}
	token, err := secret.Hex(32)
	if err != nil {
		return Session{}, err
	}
	now := time.Now().UTC()
	session := Session{
		Token:       token,
		Fingerprint: fingerprint,
		DeviceName:  strings.TrimSpace(deviceName),
		CreatedAt:   now.Format(time.RFC3339),
		ExpiresAt:   now.Add(ttl).Format(time.RFC3339),
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[token] = session
	if err := m.saveLocked(); err != nil {
		delete(m.sessions, token)
		return Session{}, err
	}
	return session, nil
}

// ValidateSession checks whether a session token is valid and not expired.
func (m *SessionManager) ValidateSession(token string) (Session, bool) {
	token = strings.TrimSpace(token)
	if token == "" {
		return Session{}, false
	}
	m.mu.RLock()
	session, exists := m.sessions[token]
	m.mu.RUnlock()
	if !exists {
		return Session{}, false
	}
	exp, err := time.Parse(time.RFC3339, session.ExpiresAt)
	if err != nil || !time.Now().UTC().Before(exp) {
		m.mu.Lock()
		delete(m.sessions, token)
		_ = m.saveLocked()
		m.mu.Unlock()
		return Session{}, false
	}
	return session, true
}

// RevokeSession removes an active session token.
func (m *SessionManager) RevokeSession(token string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.sessions[token]; !exists {
		return nil
	}
	delete(m.sessions, token)
	return m.saveLocked()
}

// RevokeFingerprint invalidates all sessions for a given device fingerprint.
func (m *SessionManager) RevokeFingerprint(fingerprint string) error {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	m.mu.Lock()
	defer m.mu.Unlock()
	changed := false
	for token, s := range m.sessions {
		if s.Fingerprint == fingerprint {
			delete(m.sessions, token)
			changed = true
		}
	}
	if changed {
		return m.saveLocked()
	}
	return nil
}

// IssueTicket creates a short-lived single-use ticket for cross-origin/cross-port app handoff.
func (m *SessionManager) IssueTicket(fingerprint string) (string, error) {
	fingerprint = strings.ToLower(strings.TrimSpace(fingerprint))
	if !validHex64.MatchString(fingerprint) {
		return "", errors.New("invalid device fingerprint")
	}
	ticketStr, err := secret.Hex(16)
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.tickets[ticketStr] = ticketRecord{
		fingerprint: fingerprint,
		expiresAt:   time.Now().UTC().Add(DefaultTicketTTL),
	}
	return ticketStr, nil
}

// RedeemTicket redeems and consumes a single-use ticket, returning the associated fingerprint.
func (m *SessionManager) RedeemTicket(ticketStr string) (string, bool) {
	ticketStr = strings.TrimSpace(ticketStr)
	if ticketStr == "" {
		return "", false
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	rec, exists := m.tickets[ticketStr]
	if !exists {
		return "", false
	}
	delete(m.tickets, ticketStr)
	if !time.Now().UTC().Before(rec.expiresAt) {
		return "", false
	}
	return rec.fingerprint, true
}
