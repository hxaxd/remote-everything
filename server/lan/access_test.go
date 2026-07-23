package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLANAccessRequiresTokenOnlyOnControlPaths(t *testing.T) {
	var seenAuth []string
	next := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		seenAuth = append(seenAuth, request.URL.Path+"|"+request.Header.Get("Authorization"))
		_, _ = io.WriteString(writer, "ok")
	})
	handler := lanAccessHandler(strings.Repeat("ab", 32), next)

	unauth := httptest.NewRecorder()
	handler.ServeHTTP(unauth, httptest.NewRequest(http.MethodGet, "/__remote_everything/apps", nil))
	if unauth.Code != http.StatusUnauthorized {
		t.Fatalf("catalog without token: %d", unauth.Code)
	}

	auth := httptest.NewRequest(http.MethodGet, "/__remote_everything/open/kimi", nil)
	auth.Header.Set("Authorization", "Bearer "+strings.Repeat("ab", 32))
	opened := httptest.NewRecorder()
	handler.ServeHTTP(opened, auth)
	if opened.Code != http.StatusOK || seenAuth[len(seenAuth)-1] != "/__remote_everything/open/kimi|" {
		t.Fatalf("open should accept token and strip it: %d %v", opened.Code, seenAuth)
	}

	page := httptest.NewRequest(http.MethodGet, "/api/v1/ws", nil)
	page.Header.Set("Authorization", "Bearer kimi-app-token")
	proxied := httptest.NewRecorder()
	handler.ServeHTTP(proxied, page)
	if proxied.Code != http.StatusOK || seenAuth[len(seenAuth)-1] != "/api/v1/ws|Bearer kimi-app-token" {
		t.Fatalf("app traffic should not require LAN token: %d %v", proxied.Code, seenAuth)
	}

	lanOnApp := httptest.NewRequest(http.MethodGet, "/assets/app.js", nil)
	lanOnApp.Header.Set("Authorization", "Bearer "+strings.Repeat("ab", 32))
	stripped := httptest.NewRecorder()
	handler.ServeHTTP(stripped, lanOnApp)
	if stripped.Code != http.StatusOK || seenAuth[len(seenAuth)-1] != "/assets/app.js|" {
		t.Fatalf("LAN bearer must not reach app backends: %d %v", stripped.Code, seenAuth)
	}
}
