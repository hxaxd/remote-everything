package main

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/hxaxd/remote-everything/internal/gatewaycore"
)

// lanAccessHandler requires the LAN access token only for control/catalog/open paths.
// Application page traffic (static assets, XHR, WebSocket) cannot carry that header from a
// mobile WebView after the first loadUrl, and apps such as KimiWeb need Authorization for
// their own bearer token. Those requests are authorized by the routing cookie set during open.
func lanAccessHandler(accessToken string, next http.Handler) http.Handler {
	expected := "Bearer " + accessToken
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/healthz" {
			next.ServeHTTP(writer, request)
			return
		}
		if strings.HasPrefix(request.URL.Path, "/__remote_everything") {
			provided := request.Header.Get("Authorization")
			if subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
				gatewaycore.WriteJSON(writer, http.StatusUnauthorized, gatewaycore.Error("unauthorized"))
				return
			}
			request.Header.Del("Authorization")
			next.ServeHTTP(writer, request)
			return
		}
		if subtle.ConstantTimeCompare([]byte(request.Header.Get("Authorization")), []byte(expected)) == 1 {
			request.Header.Del("Authorization")
		}
		next.ServeHTTP(writer, request)
	})
}
