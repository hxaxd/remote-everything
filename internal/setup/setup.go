package setup

import (
	"errors"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	qrcode "github.com/skip2/go-qrcode"
)

var (
	hex64      = regexp.MustCompile(`^[a-f0-9]{64}$`)
	invitation = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
)

func normalizeOrigin(value string) (string, error) {
	parsed, err := url.Parse(strings.TrimSpace(value))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.EscapedPath() != "" && parsed.EscapedPath() != "/") {
		return "", errors.New("origin must be an HTTPS origin")
	}
	if portText := parsed.Port(); portText != "" {
		port, portErr := strconv.Atoi(portText)
		if portErr != nil || port < 1 || port > 65535 {
			return "", errors.New("origin must use a valid port")
		}
	}
	return "https://" + parsed.Host, nil
}

func Build(mode, installationID, name, origin, secret string) (string, error) {
	if !hex64.MatchString(installationID) {
		return "", errors.New("invalid installation id")
	}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 80 || strings.IndexFunc(name, func(character rune) bool { return character < 32 || character == 127 }) >= 0 {
		return "", errors.New("invalid installation name")
	}
	normalizedOrigin, err := normalizeOrigin(origin)
	if err != nil {
		return "", err
	}
	values := url.Values{
		"v":      {"1"},
		"id":     {installationID},
		"name":   {name},
		"mode":   {mode},
		"origin": {normalizedOrigin},
	}
	switch mode {
	case "lan":
		if !hex64.MatchString(secret) {
			return "", errors.New("invalid LAN certificate fingerprint")
		}
		values.Set("fingerprint", secret)
	case "public":
		if !invitation.MatchString(secret) {
			return "", errors.New("invalid public invitation")
		}
		values.Set("invitation", secret)
	default:
		return "", errors.New("invalid setup mode")
	}
	return (&url.URL{Scheme: "remote-everything", Host: "setup", RawQuery: values.Encode()}).String(), nil
}

func WriteQR(path, payload string) error {
	if path == "" {
		return nil
	}
	if !filepath.IsAbs(path) {
		return errors.New("QR path must be absolute")
	}
	image, err := qrcode.Encode(payload, qrcode.Medium, 512)
	if err != nil {
		return err
	}
	return atomicfile.Write(filepath.Clean(path), image, 0o600)
}
