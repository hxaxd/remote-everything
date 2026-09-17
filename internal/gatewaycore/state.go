package gatewaycore

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"slices"
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

// Node is one computer a gateway serves. ID is the node's own identity, which
// its init minted and its state keeps: the same computer is the same node
// whichever gateway reaches it, and a device's access is granted and withdrawn
// per node. Name is the label its operator gave it. Address is where this
// gateway reaches that node's control plane — that machine's own address on the
// same network, or a local address a tunnel in front of it forwards from; which
// of the two it is belongs to the shape, and a gateway only dials what it is.
type Node struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Address string `json:"address"`
}

// State is what every gateway records about itself: the identity a node binds it
// by, the origin its clients dial, the listeners it serves, and the nodes it
// serves those listeners for. A gateway whose trust material needs more than that
// keeps it in its own part of its own state file.
type State struct {
	Schema         int        `json:"schema"`
	InstallationID string     `json:"installation_id"`
	Origin         string     `json:"origin"`
	Listeners      []Listener `json:"listeners"`
	Nodes          []Node     `json:"nodes"`
}

// ValidNodeName is the shape of the label an operator gives a node. It is what a
// client shows, so it has to be printable and it has to be there. It is exported
// because the URI an invitation is delivered in carries the same label, and the
// two must agree about what a name is.
func ValidNodeName(value string) bool {
	if value == "" || strings.TrimSpace(value) != value || len([]rune(value)) > 80 {
		return false
	}
	return strings.IndexFunc(value, func(character rune) bool { return character < 32 || character == 127 }) < 0
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
// keeps more in its own file validates that itself. A gateway that has not been
// given a node yet is valid — its init records the gateway before there is
// anything behind it — and serving one is refused where the gateway is opened.
func (state State) Validate() error {
	// A gateway always says which nodes it serves, even when that is none yet: a
	// state that does not is one whose nodes were not written down.
	if state.Schema != StateSchema || !validToken.MatchString(state.InstallationID) || len(state.Listeners) == 0 || state.Nodes == nil {
		return errors.New("invalid gateway state")
	}
	if origin, err := NormalizeOrigin(state.Origin); err != nil || origin != state.Origin {
		return errors.New("invalid gateway state")
	}
	// Everything the gateway reaches or serves has an address of its own: two
	// entries sharing one would answer for each other.
	seenNames := map[string]bool{}
	seenAddresses := map[string]bool{}
	for _, listener := range state.Listeners {
		if !validID.MatchString(listener.Name) || seenNames[listener.Name] || !netaddr.ValidListen(listener.Address) || seenAddresses[listener.Address] {
			return errors.New("invalid gateway state")
		}
		seenNames[listener.Name] = true
		seenAddresses[listener.Address] = true
	}
	seenNodes := map[string]bool{}
	seenNodeNames := map[string]bool{}
	for _, node := range state.Nodes {
		if !validToken.MatchString(node.ID) || seenNodes[node.ID] || !ValidNodeName(node.Name) || seenNodeNames[node.Name] ||
			!netaddr.ValidUnicast(node.Address) || seenAddresses[node.Address] {
			return errors.New("invalid gateway state")
		}
		seenNodes[node.ID] = true
		seenNodeNames[node.Name] = true
		seenAddresses[node.Address] = true
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

// FindNode returns the node with the given id, when this gateway serves it.
func (state State) FindNode(id string) (Node, bool) {
	return FindNode(state.Nodes, id)
}

// FindNode returns the node with the given id among the nodes a gateway serves.
func FindNode(nodes []Node, id string) (Node, bool) {
	for _, node := range nodes {
		if node.ID == id {
			return node, true
		}
	}
	return Node{}, false
}

// ResolveNode finds the node an operator named, by the name it was given or by its
// id: a name is what an operator types, and a node id is 64 hex characters that
// nobody reads out loud. It is one rule with one home, because the operator names
// a node the same way whichever command they are running.
func ResolveNode(nodes []Node, value string) (Node, error) {
	value = strings.TrimSpace(value)
	for _, node := range nodes {
		if node.Name == value {
			return node, nil
		}
	}
	if node, ok := FindNode(nodes, value); ok {
		return node, nil
	}
	return Node{}, fmt.Errorf("this gateway serves no node called %s", value)
}

// AddNode records a node this gateway serves, or brings one it already serves up
// to date: the same node is added again when the operator renamed it or when its
// address moved. A name belongs to one node, because a name is how an operator
// and a client pick which machine they mean.
func (state State) AddNode(node Node) (State, error) {
	nodes := slices.Clone(state.Nodes)
	replaced := false
	for index, existing := range nodes {
		if existing.ID == node.ID {
			nodes[index] = node
			replaced = true
			continue
		}
		if existing.Name == node.Name {
			return State{}, errors.New("another node already has that name")
		}
	}
	if !replaced {
		nodes = append(nodes, node)
	}
	state.Nodes = nodes
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}

// RemoveNode drops a node this gateway serves. A machine is taken out of a
// gateway when it is decommissioned or handed to somebody else, and what is left
// of it here is nothing: whoever removes one takes the token it authenticated with
// and the devices' access to it with it.
func (state State) RemoveNode(id string) (State, error) {
	nodes := make([]Node, 0, len(state.Nodes))
	found := false
	for _, node := range state.Nodes {
		if node.ID == id {
			found = true
			continue
		}
		nodes = append(nodes, node)
	}
	if !found {
		return State{}, errors.New("this gateway serves no such node")
	}
	state.Nodes = nodes
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}

// AllocateListeners reserves one address per preference, in order, each staying
// clear of the ones before it. It is what a gateway's own listeners and, for a
// shape that owns them, each node's address are reserved with. It comes before
// NewState because an origin may be what the allocated addresses say it is: a
// gateway that dials itself by its own host and port derives its origin from the
// listeners, while one served by an entrance in front of it is told its origin.
func AllocateListeners(preferences []ListenerPreference) ([]Listener, error) {
	listeners := make([]Listener, 0, len(preferences))
	seen := map[string]bool{}
	for _, preference := range preferences {
		address, err := allocateAddress(preference.Host, preference.PreferredPort, seen)
		if err != nil {
			return nil, fmt.Errorf("no address available for the %s listener: %w", preference.Name, err)
		}
		seen[address] = true
		listeners = append(listeners, Listener{Name: preference.Name, Address: address})
	}
	return listeners, nil
}

// AllocateNodeAddress reserves where the gateway reaches one more node: the same
// reservation the gateway's own listeners go through, staying clear of every
// address this gateway already uses.
func (state State) AllocateNodeAddress(host string, preferredPort int) (string, error) {
	addresses, err := allocateAddresses([]string{host}, preferredPort, state.usedAddresses())
	if err != nil {
		return "", err
	}
	return addresses[0], nil
}

// servedAddresses is the addresses this gateway serves on. A reservation stays
// clear of them: two entries sharing one address would answer for each other.
func (state State) servedAddresses() map[string]bool {
	seen := make(map[string]bool, len(state.Listeners))
	for _, listener := range state.Listeners {
		seen[listener.Address] = true
	}
	return seen
}

// usedAddresses is every address this state already occupies: the ones it serves
// on and the ones it reaches its nodes at.
func (state State) usedAddresses() map[string]bool {
	seen := state.servedAddresses()
	for _, node := range state.Nodes {
		seen[node.Address] = true
	}
	return seen
}

// allocateAddresses reserves one address per host, trying the preferred port for
// each and then any port, skipping the addresses the caller already occupies. It
// is one reservation for everything this project allocates, so a node's address
// and a listener's are reserved the same way; every address it returns is
// distinct.
func allocateAddresses(hosts []string, preferredPort int, taken map[string]bool) ([]string, error) {
	addresses := make([]string, 0, len(hosts))
	for _, host := range hosts {
		address, err := allocateAddress(host, preferredPort, taken)
		if err != nil {
			return nil, fmt.Errorf("no address available on %s: %w", host, err)
		}
		taken[address] = true
		addresses = append(addresses, address)
	}
	return addresses, nil
}

// allocateAddress reserves one address, trying the preferred port first and then
// any port, and skipping the ones already taken by this state.
func allocateAddress(host string, preferredPort int, taken map[string]bool) (string, error) {
	port := preferredPort
	for attempt := 0; attempt < 16; attempt++ {
		address, err := netaddr.Reserve(host, port)
		if err != nil {
			return "", err
		}
		if !taken[address] {
			return address, nil
		}
		port = 0
	}
	return "", errors.New("no port available")
}

// NewState records a gateway: the identity a node binds it by, the origin its
// clients dial, and the addresses it serves on. The nodes it serves are added
// afterwards, one at a time, because each one is handed over to a separate
// machine before it is part of this gateway.
func NewState(installationID, origin string, listeners []Listener) (State, error) {
	if !validToken.MatchString(installationID) {
		return State{}, errors.New("invalid gateway identity")
	}
	normalizedOrigin, err := NormalizeOrigin(origin)
	if err != nil {
		return State{}, err
	}
	state := State{Schema: StateSchema, InstallationID: installationID, Origin: normalizedOrigin, Listeners: listeners, Nodes: []Node{}}
	if err := state.Validate(); err != nil {
		return State{}, err
	}
	return state, nil
}

// Repair reallocates every listener, keeping each one's name and host: the
// addresses are what clients and peers were pointed at, so only the ports move.
// The nodes keep the addresses they were added with — where a node is belongs to
// whoever added it, and a shape that owns its node addresses repairs them itself.
func (state State) Repair(preferred map[string]int) (State, error) {
	preferences := make([]ListenerPreference, 0, len(state.Listeners))
	for _, listener := range state.Listeners {
		host, _, err := net.SplitHostPort(listener.Address)
		if err != nil {
			return State{}, err
		}
		preferences = append(preferences, ListenerPreference{Name: listener.Name, Host: host, PreferredPort: preferred[listener.Name]})
	}
	listeners, err := AllocateListeners(preferences)
	if err != nil {
		return State{}, err
	}
	return State{Schema: state.Schema, InstallationID: state.InstallationID, Origin: state.Origin, Listeners: listeners, Nodes: state.Nodes}, nil
}

// RepairNodePorts reallocates the address of every node, keeping each node's id
// and name. It is for a shape that owns those addresses — a tunnel port the
// gateway's own tunnel server holds — rather than for one whose nodes are dialed
// where they are. Every node's address is being replaced, so what the new ones
// have to stay clear of is where this gateway itself serves.
func (state State) RepairNodePorts(preferredPort int) (State, error) {
	hosts := make([]string, 0, len(state.Nodes))
	for _, node := range state.Nodes {
		host, _, err := net.SplitHostPort(node.Address)
		if err != nil {
			return State{}, err
		}
		hosts = append(hosts, host)
	}
	addresses, err := allocateAddresses(hosts, preferredPort, state.servedAddresses())
	if err != nil {
		return State{}, err
	}
	repaired := State{Schema: state.Schema, InstallationID: state.InstallationID, Origin: state.Origin, Listeners: state.Listeners, Nodes: make([]Node, 0, len(state.Nodes))}
	for index, node := range state.Nodes {
		repaired.Nodes = append(repaired.Nodes, Node{ID: node.ID, Name: node.Name, Address: addresses[index]})
	}
	if err := repaired.Validate(); err != nil {
		return State{}, err
	}
	return repaired, nil
}
