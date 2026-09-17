// Package deploymentbootstrap is the identity a gateway hands to a node: the one
// document an operator carries between the two machines. A gateway runs wherever it
// runs, so this is the only way it reaches a node — there is no gateway that imports
// its own binding — and a node knows a gateway by this and nothing else: not its
// certificates, not its tunnel, not its other nodes.
//
// What a gateway owns on its own machine belongs to the gateway, and the shape that
// owns a tunnel keeps its material in its own package.
package deploymentbootstrap

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
)

const (
	Schema           = 1
	ManifestName     = "bootstrap.json"
	ControlTokenName = "control-token"
)

var hex64 = regexp.MustCompile(`^[a-f0-9]{64}$`)

// Manifest describes the identity bundle a gateway hands to a node. It carries
// the installation identity and the control token and nothing else: a node
// knows its gateways by identity alone, and everything else a gateway owns —
// its certificates, its tunnel — stays on the gateway side.
type Manifest struct {
	Schema         int    `json:"schema"`
	InstallationID string `json:"installation_id"`
	ControlToken   string `json:"control_token_file"`
}

type NodeBundle struct {
	InstallationID string
	ControlToken   string
}

// WriteNodeBundle writes the identity bundle an operator carries to a node.
// Writing the same identity twice is idempotent; a bundle that already holds
// another identity is refused rather than overwritten, because a node is handed
// what it binds with once and a silent replacement would leave that machine
// authenticating with a token this gateway no longer has.
func WriteNodeBundle(root, installationID, controlToken string) error {
	if !filepath.IsAbs(root) {
		return errors.New("bootstrap output path must be absolute")
	}
	if !hex64.MatchString(installationID) || !hex64.MatchString(controlToken) {
		return errors.New("invalid bootstrap identity")
	}
	root = filepath.Clean(root)
	if _, err := os.Stat(filepath.Join(root, ManifestName)); err == nil {
		existing, readErr := ReadNodeBundle(root)
		if readErr != nil {
			return readErr
		}
		if existing.InstallationID != installationID || existing.ControlToken != controlToken {
			return errors.New("existing node bootstrap does not match gateway")
		}
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return writeNodeBundle(root, installationID, controlToken)
}

// ReplaceNodeBundle writes the same bundle over one that is already there. It is
// how a replaced control token reaches the machine it belongs to: the operator
// asked for the replacement, and the machine replaces its binding with what it is
// handed — the only thing that can tell it, since a node never reaches back here.
func ReplaceNodeBundle(root, installationID, controlToken string) error {
	if !filepath.IsAbs(root) {
		return errors.New("bootstrap output path must be absolute")
	}
	if !hex64.MatchString(installationID) || !hex64.MatchString(controlToken) {
		return errors.New("invalid bootstrap identity")
	}
	return writeNodeBundle(filepath.Clean(root), installationID, controlToken)
}

func writeNodeBundle(root, installationID, controlToken string) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	if err := atomicfile.Write(filepath.Join(root, ControlTokenName), []byte(controlToken+"\n"), 0o600); err != nil {
		return err
	}
	manifest := Manifest{Schema: Schema, InstallationID: installationID, ControlToken: ControlTokenName}
	contents, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	return atomicfile.Write(filepath.Join(root, ManifestName), append(contents, '\n'), 0o600)
}

func decodeManifest(path string, output *Manifest) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder := json.NewDecoder(file)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(output); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return errors.New("trailing bootstrap JSON")
	}
	return nil
}

func ReadNodeBundle(root string) (NodeBundle, error) {
	if !filepath.IsAbs(root) {
		return NodeBundle{}, errors.New("bootstrap path must be absolute")
	}
	root = filepath.Clean(root)
	var manifest Manifest
	if err := decodeManifest(filepath.Join(root, ManifestName), &manifest); err != nil {
		return NodeBundle{}, err
	}
	if manifest.Schema != Schema || !hex64.MatchString(manifest.InstallationID) ||
		manifest.ControlToken != ControlTokenName {
		return NodeBundle{}, errors.New("invalid bootstrap manifest")
	}
	contents, err := os.ReadFile(filepath.Join(root, ControlTokenName))
	if err != nil {
		return NodeBundle{}, err
	}
	bundle := NodeBundle{InstallationID: manifest.InstallationID, ControlToken: strings.TrimRight(string(contents), "\r\n")}
	if !hex64.MatchString(bundle.ControlToken) {
		return NodeBundle{}, errors.New("invalid bootstrap token")
	}
	return bundle, nil
}
