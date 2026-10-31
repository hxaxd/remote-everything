// Package webloading covers browser application documents until their first content paint.
package webloading

import (
	"bufio"
	"bytes"
	"context"
	_ "embed"
	"io"
	"net/http"
	"regexp"
	"strings"
)

const ScriptPath = "/__remote_everything_web_loading.js"
const ThemeHeader = "X-Remote-Everything-Web-Appearance"

//go:embed loading.js
var Script []byte

type themeKey struct{}

func WithTheme(r *http.Request, theme string) *http.Request {
	if theme != "dark" && theme != "light" {
		return r
	}
	return r.WithContext(context.WithValue(r.Context(), themeKey{}, theme))
}
func document(r *http.Request) bool {
	return r.Method == http.MethodGet && (r.Header.Get("Sec-Fetch-Dest") == "document" || strings.Contains(r.Header.Get("Accept"), "text/html"))
}

// Prepare requests an uncompressed document so the response can be prefixed without buffering the page.
func Prepare(r *http.Request) {
	if _, ok := r.Context().Value(themeKey{}).(string); ok && document(r) {
		r.Header.Set("Accept-Encoding", "identity")
		r.Header.Del("If-None-Match")
		r.Header.Del("If-Modified-Since")
	}
}

type prefixedBody struct {
	io.Reader
	io.Closer
}

var headTag = regexp.MustCompile(`(?i)<head(?:\s[^>]*)?>`)
var nonceSource = regexp.MustCompile(`'nonce-([a-zA-Z0-9+/_=-]+)'`)

// Apply changes only authenticated browser HTML documents. Streaming and upgraded responses pass through.
func Apply(response *http.Response) error {
	r := response.Request
	if r == nil {
		return nil
	}
	theme, ok := r.Context().Value(themeKey{}).(string)
	if !ok || !document(r) || response.StatusCode != http.StatusOK || !strings.HasPrefix(strings.ToLower(response.Header.Get("Content-Type")), "text/html") {
		return nil
	}
	if encoding := response.Header.Get("Content-Encoding"); encoding != "" && encoding != "identity" {
		return nil
	}
	reader := bufio.NewReader(response.Body)
	var prefix []byte
	var position []int
	for len(prefix) < 64*1024 {
		part, err := reader.ReadSlice('>')
		prefix = append(prefix, part...)
		if position = headTag.FindIndex(prefix); position != nil {
			break
		}
		if err != nil && err != bufio.ErrBufferFull {
			break
		}
	}
	original := response.Body
	if position != nil {
		nonce := ""
		if match := nonceSource.FindStringSubmatch(response.Header.Get("Content-Security-Policy")); match != nil {
			nonce = ` nonce="` + match[1] + `"`
		}
		addition := `<meta name="color-scheme" content="` + theme + `"><script src="` + ScriptPath + `" data-scheme="` + theme + `"` + nonce + `></script>`
		prefix = append(append(append([]byte{}, prefix[:position[1]]...), []byte(addition)...), prefix[position[1]:]...)
		response.ContentLength = -1
		for _, header := range []string{"Content-Length", "ETag", "Content-MD5", "Digest"} {
			response.Header.Del(header)
		}
		response.Header.Set("Cache-Control", "private, no-store")
	}
	response.Body = &prefixedBody{Reader: io.MultiReader(bytes.NewReader(prefix), reader), Closer: original}
	return nil
}
