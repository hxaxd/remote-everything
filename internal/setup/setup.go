package setup

import (
	"errors"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
	"github.com/hxaxd/remote-everything/internal/gatewaycore"
	qrcode "github.com/skip2/go-qrcode"
)

var (
	hex64               = regexp.MustCompile(`^[a-f0-9]{64}$`)
	invitationPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	publicKeyPinPattern = regexp.MustCompile(`^[A-Za-z0-9+/]{43}=$`)
)

// Build renders the URI a gateway delivers an invitation in.
//
// The invitation is what every URI carries: it is the secret a device redeems for
// a credential, and it is the only thing that admits one. Beside it, a gateway
// that serves a certificate of its own states it, because nothing else signs that
// gateway and its clients have nowhere else to learn which certificate to expect.
// Which of the two a client is looking at is that fact and nothing else, so the
// mode it reads is derived here from the pins rather than handed in: an entrance
// does not have to name itself for the two to agree.
func Build(installationID, name, origin, invitation, certificateFingerprint, publicKeyPin string) (string, error) {
	if !hex64.MatchString(installationID) {
		return "", errors.New("invalid installation id")
	}
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 80 || strings.IndexFunc(name, func(character rune) bool { return character < 32 || character == 127 }) >= 0 {
		return "", errors.New("invalid installation name")
	}
	normalizedOrigin, err := gatewaycore.NormalizeOrigin(origin)
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
		"mode":       {"public"},
		"origin":     {normalizedOrigin},
		"invitation": {invitation},
	}
	// A gateway that serves a certificate of its own pins it, and both halves of
	// that pin are required together: a client that is told to expect a
	// certificate it cannot check would be worse off than one told to trust the
	// system.
	if certificateFingerprint != "" || publicKeyPin != "" {
		if !hex64.MatchString(certificateFingerprint) || !publicKeyPinPattern.MatchString(publicKeyPin) {
			return "", errors.New("invalid setup certificate pins")
		}
		values.Set("mode", "lan")
		values.Set("fingerprint", certificateFingerprint)
		values.Set("public_key_pin", publicKeyPin)
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
