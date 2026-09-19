package main

import (
	"net/http"
	"testing"
	"time"

	"github.com/hxaxd/remote-everything/internal/webclient"
)

func TestPublicApplicationCookiesStayOnCurrentHost(t *testing.T) {
	for _, tc := range []struct {
		name, raw string
		want      bool
	}{
		{"parent domain", "session=secret; Domain=.example.com; Path=/app; HttpOnly; SameSite=Lax; Max-Age=3600", true},
		{"current host", "session=secret; Domain=app.example.com; Path=/", true},
		{"mixed case duplicates", "session=secret; dOmAiN=example.com; DOMAIN=other.test; Path=/", true},
		{"host cookie", "session=secret; Path=/", true},
		{"deletion", "session=; Domain=example.com; Path=/app; Max-Age=0; HttpOnly", true},
		{"partitioned", "session=secret; Domain=example.com; Path=/; SameSite=None; Partitioned", true},
		{"reserved gateway cookie", webclient.HostSessionCookieName + "=forged; Path=/; Secure", false},
		{"invalid cookie", "=secret; Domain=example.com", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := http.Header{}
			h.Add("Set-Cookie", tc.raw)
			h.Add("Set-Cookie", "preference=dark; Path=/")
			restrictPublicApplicationCookies(h)
			got := (&http.Response{Header: h}).Cookies()
			count := 1
			if tc.want {
				count++
			}
			if len(got) != count {
				t.Fatalf("cookies: %v", h.Values("Set-Cookie"))
			}
			for _, cookie := range got {
				if cookie.Domain != "" || !cookie.Secure {
					t.Fatalf("not host-restricted: %+v", cookie)
				}
			}
			if !tc.want {
				return
			}
			original, err := http.ParseSetCookie(tc.raw)
			if err != nil {
				t.Fatal(err)
			}
			if got[0].Name != original.Name || got[0].Value != original.Value || got[0].Path != original.Path || got[0].MaxAge != original.MaxAge || got[0].HttpOnly != original.HttpOnly || got[0].SameSite != original.SameSite || got[0].Partitioned != original.Partitioned {
				t.Fatalf("cookie semantics changed: %+v", got[0])
			}
		})
	}
}

func TestPublicCookiePolicyPreservesExpiry(t *testing.T) {
	expires := time.Now().UTC().Truncate(time.Second).Add(time.Hour)
	h := http.Header{}
	h.Add("Set-Cookie", (&http.Cookie{Name: "session", Value: "value", Domain: "example.com", Path: "/", Expires: expires}).String())
	restrictPublicApplicationCookies(h)
	cookie := (&http.Response{Header: h}).Cookies()[0]
	if !cookie.Expires.Equal(expires) {
		t.Fatal("expiry changed")
	}
}
