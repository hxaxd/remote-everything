package gatewaycore

import (
	"errors"
	"fmt"
	"net"

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
// by and the listeners it serves. A gateway whose trust material needs more than
// that keeps it in its own part of its own state file.
type State struct {
	Schema         int        `json:"schema"`
	InstallationID string     `json:"installation_id"`
	Listeners      []Listener `json:"listeners"`
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

// NewState allocates the listeners of a fresh gateway.
func NewState(installationID string, preferences []ListenerPreference) (State, error) {
	if !validToken.MatchString(installationID) || len(preferences) == 0 {
		return State{}, errors.New("invalid gateway identity")
	}
	listeners, err := allocate(preferences)
	if err != nil {
		return State{}, err
	}
	return State{Schema: StateSchema, InstallationID: installationID, Listeners: listeners}, nil
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
	return State{Schema: state.Schema, InstallationID: state.InstallationID, Listeners: listeners}, nil
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
