package nodecore

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/hxaxd/remote-everything/internal/atomicfile"
)

const registrySchema = 1

var (
	validID     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	validAccent = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
)

type AppDefinition struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Description    string   `json:"description"`
	Icon           string   `json:"icon"`
	Accent         string   `json:"accent"`
	LaunchFragment string   `json:"launch_fragment"`
	ProxyURL       string   `json:"proxy_url"`
	Command        string   `json:"command"`
	Arguments      []string `json:"arguments"`
	StopCommand    string   `json:"stop_command"`
	StopArgs       []string `json:"stop_arguments"`
	WorkDir        string   `json:"workdir"`
}

type Registry struct {
	Schema int             `json:"schema"`
	Apps   []AppDefinition `json:"apps"`
}

type AppMutationResult struct {
	OK      bool   `json:"ok"`
	Action  string `json:"action"`
	ID      string `json:"id"`
	Changed bool   `json:"changed"`
}

func validDirectory(path string) bool {
	if path == "" {
		return true
	}
	if !filepath.IsAbs(path) {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func proxyAddress(rawURL string) (string, error) {
	target, err := url.Parse(rawURL)
	if err != nil || target.Scheme != "http" || target.Hostname() != "127.0.0.1" || target.User != nil || target.Fragment != "" {
		return "", errors.New("proxy_url must be loopback HTTP")
	}
	if target.Path != "" && target.Path != "/" || target.RawQuery != "" {
		return "", errors.New("proxy_url must not contain a path or query")
	}
	port, err := strconv.Atoi(target.Port())
	if err != nil || port < 1 || port > 65535 {
		return "", errors.New("proxy_url must contain a valid port")
	}
	return net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), nil
}

func validMetadata(value string, maximum int, allowEmpty bool) bool {
	if strings.TrimSpace(value) != value || (!allowEmpty && value == "") || len([]rune(value)) > maximum {
		return false
	}
	for _, character := range value {
		if character < 32 || character == 127 {
			return false
		}
	}
	return true
}

func validLaunchFragment(value string) bool {
	return value == "" || (strings.HasPrefix(value, "#") && validMetadata(value, 2048, false))
}

func (node *Node) validateRegistry(value Registry) error {
	if value.Schema != registrySchema || value.Apps == nil {
		return errors.New("invalid application registry schema")
	}
	seen := map[string]bool{}
	for _, app := range value.Apps {
		address, err := proxyAddress(app.ProxyURL)
		if err != nil {
			return errors.New("invalid application proxy_url")
		}
		if !validID.MatchString(app.ID) {
			return errors.New("invalid application id")
		}
		if !validMetadata(app.Name, 80, false) {
			return errors.New("invalid application name")
		}
		if !validMetadata(app.Description, 240, true) {
			return errors.New("invalid application description")
		}
		if !validMetadata(app.Icon, 4, true) {
			return errors.New("invalid application icon")
		}
		if !validAccent.MatchString(app.Accent) {
			return errors.New("invalid application accent")
		}
		if !validLaunchFragment(app.LaunchFragment) {
			return errors.New("invalid application launch_fragment")
		}
		if !filepath.IsAbs(app.Command) {
			return errors.New("application command must be absolute")
		}
		if seen[app.ID] {
			return errors.New("duplicate application id")
		}
		if address == node.state.ListenAddress {
			return errors.New("application proxy_url conflicts with node listen address")
		}
		if !validDirectory(app.WorkDir) {
			return errors.New("invalid application workdir")
		}
		if app.StopCommand != "" && !filepath.IsAbs(app.StopCommand) {
			return errors.New("application stop_command must be absolute")
		}
		if app.Arguments == nil {
			return errors.New("application arguments must be a list")
		}
		if app.StopArgs == nil {
			return errors.New("application stop_arguments must be a list")
		}
		seen[app.ID] = true
	}
	return nil
}

func (node *Node) loadRegistry() (Registry, error) {
	var value Registry
	if err := decodeSingleJSON(node.appsFile, &value); err != nil {
		return Registry{}, err
	}
	if err := node.validateRegistry(value); err != nil {
		return Registry{}, err
	}
	return value, nil
}

func (node *Node) saveRegistry(value Registry) error {
	if err := node.validateRegistry(value); err != nil {
		return err
	}
	sort.Slice(value.Apps, func(i, j int) bool { return value.Apps[i].ID < value.Apps[j].ID })
	contents, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return atomicfile.Write(node.appsFile, append(contents, '\n'), 0o600)
}

func (node *Node) readAppDefinition(path string) (AppDefinition, error) {
	info, err := os.Stat(path)
	if err != nil || info.Size() > 64*1024 {
		return AppDefinition{}, errors.New("invalid application definition")
	}
	var app AppDefinition
	if err := decodeSingleJSON(path, &app); err != nil {
		return AppDefinition{}, err
	}
	if err := node.validateRegistry(Registry{Schema: registrySchema, Apps: []AppDefinition{app}}); err != nil {
		return AppDefinition{}, err
	}
	return app, nil
}

func (node *Node) findApp(id string) (AppDefinition, error) {
	value, err := node.loadRegistry()
	if err != nil {
		return AppDefinition{}, err
	}
	for _, app := range value.Apps {
		if app.ID == id {
			return app, nil
		}
	}
	return AppDefinition{}, os.ErrNotExist
}

func (node *Node) listRegistry(output io.Writer) error {
	value, err := node.loadRegistry()
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(value)
}

func (node *Node) setApp(definition string, output io.Writer) error {
	app, err := node.readAppDefinition(definition)
	if err != nil {
		return err
	}
	value, err := node.loadRegistry()
	if err != nil {
		return err
	}
	for index := range value.Apps {
		if value.Apps[index].ID == app.ID {
			changed := !reflect.DeepEqual(value.Apps[index], app)
			value.Apps[index] = app
			if changed {
				if err := node.saveRegistry(value); err != nil {
					return err
				}
			}
			return json.NewEncoder(output).Encode(AppMutationResult{OK: true, Action: "set", ID: app.ID, Changed: changed})
		}
	}
	value.Apps = append(value.Apps, app)
	if err := node.saveRegistry(value); err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(AppMutationResult{OK: true, Action: "set", ID: app.ID, Changed: true})
}

func (node *Node) removeApp(id string, output io.Writer) error {
	if !validID.MatchString(id) {
		return errors.New("invalid application id")
	}
	value, err := node.loadRegistry()
	if err != nil {
		return err
	}
	apps := make([]AppDefinition, 0, len(value.Apps))
	changed := false
	for _, app := range value.Apps {
		if app.ID == id {
			changed = true
			continue
		}
		apps = append(apps, app)
	}
	if changed {
		value.Apps = apps
		if err := node.saveRegistry(value); err != nil {
			return err
		}
	}
	if err := os.Remove(node.enabledPath(id)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return json.NewEncoder(output).Encode(AppMutationResult{OK: true, Action: "remove", ID: id, Changed: changed})
}

func (node *Node) enabledPath(id string) string {
	return filepath.Join(node.enabledRoot, id)
}
