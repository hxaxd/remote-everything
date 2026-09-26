package webclient

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/hxaxd/remote-everything/internal/backplane/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/infra/jsonfile"
	"github.com/hxaxd/remote-everything/internal/infra/secret"
)

const (
	// SessionCookieName is the name this deployment owns and never issues: the
	// browser binds a session to one host through the `__Host-` prefix, so the
	// un-prefixed name is only ever something an application tried to write, and
	// it is dropped rather than read.
	SessionCookieName     = proxysecurity.WebSessionCookieName
	HostSessionCookieName = proxysecurity.HostWebSessionCookieName
	SessionHeaderName     = "X-Remote-Everything-Web-Token"
	RevokeHeaderName      = "X-Remote-Everything-Web-Revoke"
	UnlockHeaderName      = "X-Remote-Everything-Web-Unlock"
	TicketQueryParam      = "_reticket"
	DefaultSessionTTL     = 30 * 24 * time.Hour
	DefaultTicketTTL      = time.Minute
	sessionsFileName      = "web-sessions.json"
)

var validHex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)
var ErrUnauthorized = errors.New("unauthorized")

// Session is one browser connection. All of its application origins share its
// current access token. Unlock replaces that token; lock removes it.
// Only hashes of the independent unlock and revocation credentials are stored.
type Session struct {
	Token       string `json:"token"`
	Fingerprint string `json:"fingerprint"`
	DeviceName  string `json:"device_name"`
	CreatedAt   string `json:"created_at"`
	ExpiresAt   string `json:"expires_at"`
	UnlockHash  string `json:"unlock_hash"`
	RevokeHash  string `json:"revoke_hash"`
}
type Credentials struct {
	Session
	UnlockToken string
	RevokeToken string
}
type ticketRecord struct {
	token     string
	expiresAt time.Time
}
type sessionStore struct {
	Sessions []Session `json:"sessions"`
}
type SessionManager struct {
	root        string
	mu          sync.Mutex
	connections map[string]Session // revocation hash -> browser connection
	tickets     map[string]ticketRecord
	active      map[string]map[*int]context.CancelFunc
}

func credentialHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
func live(s Session) bool {
	expires, err := time.Parse(time.RFC3339Nano, s.ExpiresAt)
	return err == nil && time.Now().Before(expires)
}
func NewSessionManager(root string) (*SessionManager, error) {
	if root == "" || !filepath.IsAbs(root) {
		return nil, errors.New("state root must be absolute")
	}
	m := &SessionManager{root: filepath.Clean(root), connections: map[string]Session{}, tickets: map[string]ticketRecord{}, active: map[string]map[*int]context.CancelFunc{}}
	var store sessionStore
	if err := jsonfile.Read(filepath.Join(root, sessionsFileName), &store); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	for _, s := range store.Sessions {
		if live(s) && validHex64.MatchString(s.Fingerprint) && validHex64.MatchString(s.UnlockHash) && validHex64.MatchString(s.RevokeHash) && (s.Token == "" || validHex64.MatchString(s.Token)) {
			m.connections[s.RevokeHash] = s
		}
	}
	if len(store.Sessions) != len(m.connections) {
		if err := m.saveLocked(); err != nil {
			return nil, err
		}
	}
	return m, nil
}
func (m *SessionManager) saveLocked() error {
	list := make([]Session, 0, len(m.connections))
	for _, s := range m.connections {
		if live(s) {
			list = append(list, s)
		}
	}
	return jsonfile.Write(filepath.Join(m.root, sessionsFileName), sessionStore{Sessions: list}, 0600)
}

// Pair creates credentials with one fixed lifetime. Handoffs and unlocks cannot
// extend it. Pairing the same browser again also retires its previous connection.
func (m *SessionManager) Pair(fp, name string, ttl time.Duration) (Credentials, error) {
	fp = strings.ToLower(strings.TrimSpace(fp))
	if !validHex64.MatchString(fp) {
		return Credentials{}, errors.New("invalid device fingerprint")
	}
	if ttl <= 0 {
		ttl = DefaultSessionTTL
	}
	token, err := secret.Hex(32)
	if err != nil {
		return Credentials{}, err
	}
	unlock, err := secret.Hex(32)
	if err != nil {
		return Credentials{}, err
	}
	revoke, err := secret.Hex(32)
	if err != nil {
		return Credentials{}, err
	}
	now := time.Now().UTC()
	s := Session{Token: token, Fingerprint: fp, DeviceName: strings.TrimSpace(name), CreatedAt: now.Format(time.RFC3339Nano), ExpiresAt: now.Add(ttl).Format(time.RFC3339Nano), UnlockHash: credentialHash(unlock), RevokeHash: credentialHash(revoke)}
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, old := range m.connections {
		if old.Fingerprint == fp {
			m.cancelLocked(old.Token)
			delete(m.connections, key)
		}
	}
	m.connections[s.RevokeHash] = s
	if err := m.saveLocked(); err != nil {
		delete(m.connections, s.RevokeHash)
		return Credentials{}, err
	}
	return Credentials{Session: s, UnlockToken: unlock, RevokeToken: revoke}, nil
}
func (m *SessionManager) validateLocked(token string) (Session, bool) {
	if token == "" {
		return Session{}, false
	}
	for _, s := range m.connections {
		if s.Token == token && live(s) {
			return s, true
		}
	}
	return Session{}, false
}
func (m *SessionManager) ValidateSession(token string) (Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.validateLocked(strings.TrimSpace(token))
}

// Acquire registers cancellation atomically with authorization. A lock cannot
// miss a request between validation and registration, including upgraded streams.
func (m *SessionManager) Acquire(parent context.Context, token string) (Session, context.Context, func(), bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.validateLocked(token)
	if !ok {
		return Session{}, nil, nil, false
	}
	expiry, _ := time.Parse(time.RFC3339Nano, s.ExpiresAt)
	ctx, cancel := context.WithDeadline(parent, expiry)
	id := new(int)
	if m.active[token] == nil {
		m.active[token] = map[*int]context.CancelFunc{}
	}
	m.active[token][id] = cancel
	done := func() {
		cancel()
		m.mu.Lock()
		defer m.mu.Unlock()
		delete(m.active[token], id)
		if len(m.active[token]) == 0 {
			delete(m.active, token)
		}
	}
	return s, ctx, done, true
}
func (m *SessionManager) cancelLocked(token string) {
	for _, cancel := range m.active[token] {
		cancel()
	}
	delete(m.active, token)
	for ticket, rec := range m.tickets {
		if rec.token == token {
			delete(m.tickets, ticket)
		}
	}
}

// Revoke accepts a deny-only credential. It can never mint or authorize access.
// Keeping it outside the encrypted vault allows revocation even after a reload
// or when the user has forgotten the vault password. Repeated calls are safe.
func (m *SessionManager) Revoke(revokeToken string, logout bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := credentialHash(revokeToken)
	if s, ok := m.connections[key]; ok {
		m.cancelLocked(s.Token)
		if logout {
			delete(m.connections, key)
		} else {
			s.Token = ""
			m.connections[key] = s
		}
	}
	return m.saveLocked()
}
func (m *SessionManager) Unlock(unlockToken string) (Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	hash := credentialHash(unlockToken)
	for key, s := range m.connections {
		if s.UnlockHash != hash || !live(s) {
			continue
		}
		token, err := secret.Hex(32)
		if err != nil {
			return Session{}, err
		}
		m.cancelLocked(s.Token)
		s.Token = token
		m.connections[key] = s
		if err := m.saveLocked(); err != nil {
			s.Token = ""
			m.connections[key] = s
			return Session{}, err
		}
		return s, nil
	}
	return Session{}, ErrUnauthorized
}
func (m *SessionManager) RevokeFingerprint(fp string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for key, s := range m.connections {
		if s.Fingerprint == strings.ToLower(strings.TrimSpace(fp)) {
			m.cancelLocked(s.Token)
			delete(m.connections, key)
		}
	}
	return m.saveLocked()
}
func (m *SessionManager) IssueTicket(token string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.validateLocked(token); !ok {
		return "", ErrUnauthorized
	}
	ticket, err := secret.Hex(16)
	if err != nil {
		return "", err
	}
	now := time.Now()
	for key, rec := range m.tickets {
		if !now.Before(rec.expiresAt) {
			delete(m.tickets, key)
		}
	}
	m.tickets[ticket] = ticketRecord{token: token, expiresAt: now.Add(DefaultTicketTTL)}
	return ticket, nil
}

// RedeemTicket hands off the same access session, never creates a new lifetime.
func (m *SessionManager) RedeemTicket(ticket string) (Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	rec, ok := m.tickets[ticket]
	delete(m.tickets, ticket)
	if !ok || !time.Now().Before(rec.expiresAt) {
		return Session{}, false
	}
	return m.validateLocked(rec.token)
}
