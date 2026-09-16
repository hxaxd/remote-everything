package gatewaycore

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"

	"github.com/hxaxd/remote-everything/internal/jsonfile"
	"github.com/hxaxd/remote-everything/internal/netaddr"
)

// StateSchema is the version of the gateway state file.
const StateSchema = 1

// Listener is one address a gateway serves on, named so that everything around
// the gateway refers to it by role rather than by position: the renderer, the
// runtime record and the operator all address a listener by its name.
type Listener struct {
	Name    string `json:"name"`
	Address string `json:"address"`
}

// ListenerPreference asks for a listener to be allocated: a name, the host it
// serves on, and the port to try first.
type ListenerPreference struct {
	Name          string
	Host          string
	PreferredPort int
}

// State is what every gateway records about itself: the identity a node binds it
// by, the origin its clients dial, and the listeners it serves. A gateway whose
// trust material needs more than that keeps it in its own part of its own state
// file.
type State struct {
	Schema         int        `json:"schema"`
	InstallationID string     `json:"installation_id"`
	Origin         string     `json:"origin"`
	Listeners      []Listener `json:"listeners"`
}

// NormalizeOrigin checks an origin and returns it in the one form a gateway
// records and hands out: the scheme and authority a client dials, with nothing
// else in it. It is the origin's only definition, so the URI an invitation is
// delivered in and the state a gateway keeps cannot disagree about it.
func NormalizeOrigin(value string) (string, error) {
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

// LoadState reads a gateway state file.
func LoadState(path string) (State, error) {
	var state State
	if err := jsonfile.Read(path, &state); err != nil {
		return State{}, err
	}
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}

// Validate checks the part of a state file every gateway has. An entrance that
// keeps more in its own file validates that itself.
func (state State) Validate() error {
	if state.Schema != StateSchema || !validToken.MatchString(state.InstallationID) || len(state.Listeners) == 0 {
		return errors.New("invalid gateway state")
	}
	if origin, err := NormalizeOrigin(state.Origin); err != nil || origin != state.Origin {
		return errors.New("invalid gateway state")
	}
	seenNames := map[string]bool{}
	seenAddresses := map[string]bool{}
	for _, listener := range state.Listeners {
		if !validID.MatchString(listener.Name) || seenNames[listener.Name] || !netaddr.ValidListen(listener.Address) || seenAddresses[listener.Address] {
			return errors.New("invalid gateway state")
		}
		seenNames[listener.Name] = true
		seenAddresses[listener.Address] = true
	}
	return nil
}

// Save writes the state, replacing any previous one atomically.
func (state State) Save(path string) error {
	return jsonfile.Write(path, state, 0o600)
}

// Address returns the address of a named listener.
func (state State) Address(name string) (string, error) {
	for _, listener := range state.Listeners {
		if listener.Name == name {
			return listener.Address, nil
		}
	}
	return "", errors.New("gateway state has no listener named " + name)
}

// AllocateListeners reserves the addresses a gateway serves on. It comes before
// NewState because an origin may be what the allocated addresses say it is: a
// gateway that dials itself by its own host and port derives its origin from the
// listeners, while one served by an entrance in front of it is told its origin.
func AllocateListeners(preferences []ListenerPreference) ([]Listener, error) {
	return allocate(preferences)
}

// NewState records a gateway: the identity a node binds it by, the origin its
// clients dial, and the addresses it serves on.
func NewState(installationID, origin string, listeners []Listener) (State, error) {
	if !validToken.MatchString(installationID) {
		return State{}, errors.New("invalid gateway identity")
	}
	normalizedOrigin, err := NormalizeOrigin(origin)
	if err != nil {
		return State{}, err
	}
	state := State{Schema: StateSchema, InstallationID: installationID, Origin: normalizedOrigin, Listeners: listeners}
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}

// Repair reallocates every listener, keeping each one's name and host: the
// addresses are what clients and peers were pointed at, so only the ports move.
func (state State) Repair(preferred map[string]int) (State, error) {
	preferences := make([]ListenerPreference, 0, len(state.Listeners))
	for _, listener := range state.Listeners {
		host, _, err := net.SplitHostPort(listener.Address)
		if err != nil {
			return State{}, err
		}
		preferences = append(preferences, ListenerPreference{Name: listener.Name, Host: host, PreferredPort: preferred[listener.Name]})
	}
	listeners, err := allocate(preferences)
	if err != nil {
		return State{}, err
	}
	return State{Schema: state.Schema, InstallationID: state.InstallationID, Origin: state.Origin, Listeners: listeners}, nil
}

func allocate(preferences []ListenerPreference) ([]Listener, error) {
	listeners := make([]Listener, 0, len(preferences))
	seen := map[string]bool{}
	for _, preference := range preferences {
		chosen := ""
		port := preference.PreferredPort
		for attempt := 0; attempt < 16 && chosen == ""; attempt++ {
			address, err := netaddr.Reserve(preference.Host, port)
			if err != nil {
				return nil, err
			}
			if !seen[address] {
				chosen = address
				seen[address] = true
				continue
			}
			port = 0
		}
		if chosen == "" {
			return nil, fmt.Errorf("no address available for the %s listener", preference.Name)
		}
		listeners = append(listeners, Listener{Name: preference.Name, Address: chosen})
	}
	return listeners, nil
}
