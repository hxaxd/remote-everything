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
	hex64               = regexp.MustCompile(`^[a-f0-9]{64}$`)
	invitationPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	publicKeyPinPattern = regexp.MustCompile(`^[A-Za-z0-9+/]{43}=$`)
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

// Build renders the URI a gateway delivers an invitation in. The invitation is
// what both modes carry: it is the secret a device redeems for a credential, and
// it is the only thing that admits one. The LAN mode carries the entrance's own
// certificate beside it, because no authority signs that entrance and its
// clients have nowhere else to learn which certificate to expect.
func Build(mode, installationID, name, origin, invitation, certificateFingerprint, publicKeyPin string) (string, error) {
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
	if !invitationPattern.MatchString(invitation) {
		return "", errors.New("invalid setup invitation")
	}
	values := url.Values{
		"v":          {"2"},
		"id":         {installationID},
		"name":       {name},
		"mode":       {mode},
		"origin":     {normalizedOrigin},
		"invitation": {invitation},
	}
	switch mode {
	case "lan":
		if !hex64.MatchString(certificateFingerprint) || !publicKeyPinPattern.MatchString(publicKeyPin) {
			return "", errors.New("invalid LAN setup parameters")
		}
		values.Set("fingerprint", certificateFingerprint)
		values.Set("public_key_pin", publicKeyPin)
	case "public":
		if certificateFingerprint != "" || publicKeyPin != "" {
			return "", errors.New("invalid public setup parameters")
		}
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
