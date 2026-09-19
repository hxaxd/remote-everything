package gatewaycore

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

func TestApplicationResponsePolicyCoversProtocolUpgrade(t *testing.T) {
	gateway, cluster := newTestGateway(t, func(w http.ResponseWriter, r *http.Request) {
		conn, rw, err := http.NewResponseController(w).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		_, _ = rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSet-Cookie: session=app; Domain=example.com; Path=/\r\nSet-Cookie: " + proxysecurity.HostWebSessionCookieName + "=forged; Path=/; Secure\r\n\r\n")
		_ = rw.Flush()
		_, _ = io.Copy(io.Discard, conn)
	})
	gateway.SetApplicationResponsePolicy(func(h http.Header) {
		for _, cookie := range (&http.Response{Header: h}).Cookies() {
			if cookie.Name == proxysecurity.HostWebSessionCookieName {
				t.Error("shared filter must precede public policy")
			}
		}
		h.Del("Set-Cookie")
		h.Add("Set-Cookie", "session=app; Path=/; Secure")
	})
	frontend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gateway.ServeApplication(cluster.id(0), testApps[0], w, r)
	}))
	defer frontend.Close()
	u, _ := url.Parse(frontend.URL)
	conn, err := net.Dial("tcp", u.Host)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	_, _ = io.WriteString(conn, "GET / HTTP/1.1\r\nHost: "+u.Host+"\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
	response, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	cookies := response.Cookies()
	if response.StatusCode != 101 || len(cookies) != 1 || cookies[0].Domain != "" || !cookies[0].Secure {
		t.Fatalf("upgrade bypassed policy: %d %v", response.StatusCode, response.Header)
	}
}
