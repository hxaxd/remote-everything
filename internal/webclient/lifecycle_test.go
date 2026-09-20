package webclient

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestConnectionLockUnlockLogout(t *testing.T) {
	root := t.TempDir()
	m, err := NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}
	c, err := m.Pair(strings.Repeat("1", 64), "browser", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	other, err := m.Pair(strings.Repeat("2", 64), "other browser", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{c.UnlockToken, c.RevokeToken} {
		if _, ok := m.ValidateSession(secret); ok {
			t.Fatal("management credential authorized app")
		}
	}
	if _, err := m.Unlock(c.Token); err != ErrUnauthorized {
		t.Fatal("access credential unlocked browser")
	}
	ticket, err := m.IssueTicket(c.Token)
	if err != nil {
		t.Fatal(err)
	}
	handoff, ok := m.RedeemTicket(ticket)
	if !ok || handoff.Token != c.Token || handoff.ExpiresAt != c.ExpiresAt {
		t.Fatal("handoff extended or detached session")
	}
	unused, _ := m.IssueTicket(c.Token)
	_, ctx, done, ok := m.Acquire(context.Background(), c.Token)
	if !ok {
		t.Fatal("acquire")
	}
	defer done()
	if err := m.Revoke(c.RevokeToken, false); err != nil {
		t.Fatal(err)
	}
	if ctx.Err() == nil {
		t.Fatal("lock did not cancel request")
	}
	if _, ok := m.ValidateSession(handoff.Token); ok {
		t.Fatal("app remained authorized after lock")
	}
	if _, ok := m.RedeemTicket(unused); ok {
		t.Fatal("unused ticket survived lock")
	}
	if _, err := m.IssueTicket(c.Token); err != ErrUnauthorized {
		t.Fatal("revoked access minted ticket")
	}
	if _, ok := m.ValidateSession(other.Token); !ok {
		t.Fatal("lock affected another browser")
	}
	m, err = NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := m.ValidateSession(c.Token); ok {
		t.Fatal("restart resurrected locked access")
	}
	fresh, err := m.Unlock(c.UnlockToken)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Token == c.Token || fresh.ExpiresAt != c.ExpiresAt {
		t.Fatal("unlock reused access or extended lifetime")
	}
	unused, _ = m.IssueTicket(fresh.Token)
	if err := m.Revoke(c.RevokeToken, true); err != nil {
		t.Fatal(err)
	}
	if _, ok := m.RedeemTicket(unused); ok {
		t.Fatal("ticket survived logout")
	}
	m, err = NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Unlock(c.UnlockToken); err != ErrUnauthorized {
		t.Fatal("logout credential resurrected connection")
	}
	if _, ok := m.ValidateSession(fresh.Token); ok {
		t.Fatal("logout did not persist")
	}
	if err := m.Revoke(c.RevokeToken, true); err != nil {
		t.Fatal("logout retry failed", err)
	}
}

func TestExpiryAndDeviceRevocation(t *testing.T) {
	m, _ := NewSessionManager(t.TempDir())
	// What this asserts is that an access held across the moment its session expires
	// ends there — not that a machine can call two methods inside thirty
	// milliseconds, which is what a slower runner was being asked for.
	c, _ := m.Pair(strings.Repeat("3", 64), "browser", 250*time.Millisecond)
	ticket, _ := m.IssueTicket(c.Token)
	_, ctx, done, ok := m.Acquire(context.Background(), c.Token)
	if !ok {
		t.Fatal("session expired before it could be acquired")
	}
	defer done()
	select {
	case <-ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("active access survived expiry")
	}
	if _, ok := m.ValidateSession(c.Token); ok {
		t.Fatal("expired access")
	}
	if _, ok := m.RedeemTicket(ticket); ok {
		t.Fatal("expired handoff")
	}
	if _, err := m.Unlock(c.UnlockToken); err != ErrUnauthorized {
		t.Fatal("expired credential unlocked")
	}
	c, _ = m.Pair(strings.Repeat("3", 64), "browser", time.Hour)
	ticket, _ = m.IssueTicket(c.Token)
	_, ctx, done2, ok2 := m.Acquire(context.Background(), c.Token)
	if !ok2 {
		t.Fatal("paired session could not be acquired")
	}
	defer done2()
	if err := m.RevokeFingerprint(c.Fingerprint); err != nil {
		t.Fatal(err)
	}
	if ctx.Err() == nil {
		t.Fatal("device revoke left active request")
	}
	if _, ok := m.RedeemTicket(ticket); ok {
		t.Fatal("device revoke left ticket")
	}
	if _, err := m.Unlock(c.UnlockToken); err != ErrUnauthorized {
		t.Fatal("device revoke left unlock credential")
	}
}

func TestHandoffRevocationRace(t *testing.T) {
	m, _ := NewSessionManager(t.TempDir())
	for i := 0; i < 50; i++ {
		c, _ := m.Pair(strings.Repeat("4", 64), "browser", time.Hour)
		ticket, _ := m.IssueTicket(c.Token)
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			s, ok := m.RedeemTicket(ticket)
			if ok {
				_, _, done, ok := m.Acquire(context.Background(), s.Token)
				if ok {
					done()
				}
			}
		}()
		go func() {
			defer wg.Done()
			if err := m.Revoke(c.RevokeToken, false); err != nil {
				t.Error(err)
			}
		}()
		wg.Wait()
		if _, ok := m.ValidateSession(c.Token); ok {
			t.Fatal("handoff raced past lock")
		}
		if _, ok := m.RedeemTicket(ticket); ok {
			t.Fatal("ticket survived race")
		}
	}
}

func TestRevocationPersistenceFailure(t *testing.T) {
	root := t.TempDir()
	m, _ := NewSessionManager(root)
	c, _ := m.Pair(strings.Repeat("5", 64), "browser", time.Hour)
	original := m.root
	m.root = filepath.Join(root, "not-a-directory")
	if err := os.WriteFile(m.root, []byte("blocked"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.Revoke(c.RevokeToken, false); err == nil {
		t.Fatal("reported successful lock without durable save")
	}
	if _, ok := m.ValidateSession(c.Token); ok {
		t.Fatal("failed lock left live access")
	}
	m.root = original
	if err := m.Revoke(c.RevokeToken, false); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewSessionManager(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := reopened.ValidateSession(c.Token); ok {
		t.Fatal("retry did not persist lock")
	}
}

// Exercise the real ReverseProxy path, including a hijacked upgraded connection.
func TestLockClosesStreamingAndUpgradedConnections(t *testing.T) {
	for _, upgrade := range []bool{false, true} {
		t.Run(map[bool]string{false: "stream", true: "websocket"}[upgrade], func(t *testing.T) {
			backendClosed := make(chan struct{})
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				defer close(backendClosed)
				if upgrade {
					conn, rw, err := http.NewResponseController(w).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					_, _ = rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
					_ = rw.Flush()
					_, _ = io.Copy(io.Discard, conn)
				} else {
					w.Header().Set("Content-Type", "text/event-stream")
					_, _ = io.WriteString(w, "data: connected\n\n")
					_ = http.NewResponseController(w).Flush()
					<-r.Context().Done()
				}
			}))
			defer backend.Close()
			target, _ := url.Parse(backend.URL)
			m, _ := NewSessionManager(t.TempDir())
			c, _ := m.Pair(strings.Repeat("6", 64), "browser", time.Hour)
			h := &Handler{sessions: m}
			gateway := httptest.NewServer(h.WithWebSession(httputil.NewSingleHostReverseProxy(target)))
			defer gateway.Close()
			u, _ := url.Parse(gateway.URL)
			conn, err := net.Dial("tcp", u.Host)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
			headers := ""
			if upgrade {
				headers = "Connection: Upgrade\r\nUpgrade: websocket\r\n"
			}
			_, _ = io.WriteString(conn, "GET / HTTP/1.1\r\nHost: "+u.Host+"\r\nCookie: "+HostSessionCookieName+"="+c.Token+"\r\n"+headers+"\r\n")
			reader := bufio.NewReader(conn)
			resp, err := http.ReadResponse(reader, nil)
			if err != nil {
				t.Fatal(err)
			}
			if upgrade && resp.StatusCode != 101 {
				t.Fatal(resp.Status)
			}
			if !upgrade {
				buf := make([]byte, len("data: connected\n\n"))
				if _, err := io.ReadFull(resp.Body, buf); err != nil {
					t.Fatal(err)
				}
			}
			if err := m.Revoke(c.RevokeToken, false); err != nil {
				t.Fatal(err)
			}
			select {
			case <-backendClosed:
			case <-time.After(time.Second):
				t.Fatal("upstream connection survived lock")
			}
			var readErr error
			if upgrade {
				_, readErr = reader.ReadByte()
			} else {
				_, readErr = io.ReadAll(resp.Body)
			}
			if timeout, ok := readErr.(net.Error); ok && timeout.Timeout() {
				t.Fatal("browser connection survived lock")
			}
		})
	}
}
