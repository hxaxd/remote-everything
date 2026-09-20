package main

import (
	"net/http"

	"github.com/hxaxd/remote-everything/internal/webclient"
)

// restrictPublicApplicationCookies confines server-issued cookies to the current
// application host. It cannot constrain cookies written directly by page scripts.
func restrictPublicApplicationCookies(header http.Header) {
	values := header.Values("Set-Cookie")
	header.Del("Set-Cookie")
	for _, value := range values {
		cookie, err := http.ParseSetCookie(value)
		if err != nil || cookie.Name == webclient.HostSessionCookieName {
			continue
		}
		cookie.Domain = ""
		cookie.Secure = true
		header.Add("Set-Cookie", cookie.String())
	}
}
