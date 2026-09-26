package setup

import (
	"errors"
	"net/url"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/infra/atomicfile"
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
// a credential, and it is the only thing that admits one. Beside it, the URI says
// which node the invitation opens a door to and what its operator calls it — an
// invitation is for one node, and a device that has not redeemed anything yet
// still knows what it is being given — and where that gateway's clients dial it.
// A gateway that serves a certificate of its own pins it as well, because nothing
// else signs that gateway and its clients have nowhere else to learn which
// certificate to expect.
//
// What a URI does not carry is a version or a shape: an invitation describes one
// gateway and one node, and a client reads that description rather than a name for
// it. The node's label is `node_name` rather than `name`, because the name an
// operator passed the command under is the device's, and two names in one document
// have to be told apart.
func Build(nodeID, nodeName, origin, invitation, certificateFingerprint, publicKeyPin string) (string, error) {
	if !hex64.MatchString(nodeID) {
		return "", errors.New("invalid node id")
	}
	nodeName = strings.TrimSpace(nodeName)
	if !gatewaycore.ValidNodeName(nodeName) {
		return "", errors.New("invalid node name")
	}
	normalizedOrigin, err := gatewaycore.NormalizeOrigin(origin)
	if err != nil {
		return "", err
	}
	if !invitationPattern.MatchString(invitation) {
		return "", errors.New("invalid setup invitation")
	}
	values := url.Values{
		"node":       {nodeID},
		"node_name":  {nodeName},
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
