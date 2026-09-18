package gatewaycore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/logline"
	"github.com/hxaxd/remote-everything/internal/netaddr"
	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

var (
	validID     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	validToken  = regexp.MustCompile(`^[a-f0-9]{64}$`)
	validAccent = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
	appRoute    = regexp.MustCompile(`^/__remote_everything/apps/([a-z0-9][a-z0-9._-]{0,63})/(status|start|stop)$`)
	openRoute   = regexp.MustCompile(`^/__remote_everything/open/([a-z0-9][a-z0-9._-]{0,63})$`)
	// validHostLabel is one label of a hostname, which is what a domain an
	// application host is built under is made of. Digits are labels just as names
	// are, so an address of a machine is such a domain too.
	validHostLabel = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)
)

// appPrefixLength is how much of a node's id an application host carries: eight
// hex characters, which is as much of a 64-hex id as a hostname label reasonably
// carries, and enough that two nodes of one gateway sharing it is a collision
// rather than a coincidence.
const appPrefixLength = 8

// Gateway is the control plane of every node one gateway serves: each node is
// reached at the address this gateway recorded for it and authenticates it with
// that node's own token. It is asked for one of them at a time — which node a
// request is for is decided where the permission for it is, and a gateway routes
// what it was asked to route rather than reading that off the request again.
//
// The applications of those nodes are served at origins of their own, which is
// what this gateway is asked for by a shape that serves them somewhere only it
// knows: where one application is served is handed out by the addressing below and
// by nothing else.
type Gateway struct {
	nodes      []Node
	links      map[string]*nodeLink
	addressing AppAddressing
}

// nodeLink is one node as the gateway reaches it: where that node's control plane
// answers, the token this gateway authenticates itself with there, and the proxy
// that serves the node's own traffic.
type nodeLink struct {
	nodeID      string
	controlURL  string
	token       string
	client      *http.Client
	application *httputil.ReverseProxy
}

type ControlResponse struct {
	OK                bool               `json:"ok"`
	ComputerConnected bool               `json:"computer_connected"`
	Code              string             `json:"code"`
	Apps              []ApplicationState `json:"apps"`
}

type ApplicationState struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Description       string `json:"description"`
	Icon              string `json:"icon"`
	Accent            string `json:"accent"`
	LaunchFragment    string `json:"launch_fragment"`
	ComputerConnected bool   `json:"computer_connected"`
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Code              string `json:"code"`
}

type actionResponse struct {
	OK                bool   `json:"ok"`
	Action            string `json:"action"`
	ComputerConnected bool   `json:"computer_connected"`
	Enabled           bool   `json:"enabled"`
	Running           bool   `json:"running"`
	Code              string `json:"code"`
}

func Error(code string) map[string]any {
	return map[string]any{"ok": false, "code": code}
}

func WriteJSON(writer http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		body = []byte(`{"ok":false,"code":"internal_error"}`)
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Content-Length", strconv.Itoa(len(body)))
	writer.Header().Set("Cache-Control", "no-store, max-age=0")
	writer.Header().Set("Pragma", "no-cache")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_, _ = writer.Write(body)
}

// stripRoutingSetCookie drops the routing cookie from a node's answer: no
// application sets which application this browser session is looking at, and an
// application that tried to would be writing the one thing it does not own.
func stripRoutingSetCookie(header http.Header) {
	values := header.Values("Set-Cookie")
	header.Del("Set-Cookie")
	for _, value := range values {
		pair := strings.SplitN(value, ";", 2)[0]
		name, _, found := strings.Cut(pair, "=")
		if found && strings.TrimSpace(name) == proxysecurity.RoutingCookieName {
			continue
		}
		header.Add("Set-Cookie", value)
	}
}

// setRoutingCookie tells the node which application a request on an application's
// origin is for, and it does so on a request that no longer says anything else:
// a cookie of that name the client sent is dropped first, because which
// application a browser session is looking at is decided by the origin it is
// talking to and never by the client. Everything else the client carries is handed
// on exactly as it arrived — those cookies belong to the application, and this is
// not the place that gets to rewrite them.
func setRoutingCookie(request *http.Request, appID string) {
	kept := make([]string, 0, 4)
	for _, field := range strings.Split(request.Header.Get("Cookie"), ";") {
		field = strings.TrimSpace(field)
		if field == "" {
			continue
		}
		if name, _, found := strings.Cut(field, "="); found && strings.TrimSpace(name) == proxysecurity.RoutingCookieName {
			continue
		}
		kept = append(kept, field)
	}
	kept = append(kept, proxysecurity.RoutingCookieName+"="+appID)
	request.Header.Set("Cookie", strings.Join(kept, "; "))
}

// AppHost is the host one application of one node is served on, on a gateway that
// serves its applications as hosts under a domain of its own: the application's
// id, the node's id prefix, and that domain. Everything in it follows from the
// node and the application, so an application is served at the same host for as
// long as it exists — which is the whole point of it, because what a browser
// remembers about an application belongs to its origin.
func AppHost(nodeID, appID, domain string) (string, error) {
	domain = strings.ToLower(domain)
	if !validToken.MatchString(nodeID) || !ValidAppID(appID) || !validApplicationDomain(domain) {
		return "", errors.New("invalid application host")
	}
	return appID + "." + nodeID[:appPrefixLength] + "." + domain, nil
}

// ParseAppHost is AppHost read backwards: which node and which application a host
// names, when it is one of this gateway's domain's application hosts. It is
// strict about the shape it accepts — an application id, eight hex characters, the
// domain itself — because what it does not recognise names no application here,
// and a host that names none is a request this gateway has nothing to route.
func ParseAppHost(host, domain string) (nodePrefix, appID string, ok bool) {
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	if name, _, err := net.SplitHostPort(host); err == nil {
		host = name
	}
	domain = strings.ToLower(domain)
	if host == "" || !validApplicationDomain(domain) {
		return "", "", false
	}
	labels := strings.Split(host, ".")
	if len(labels) != len(strings.Split(domain, "."))+2 || !ValidAppID(labels[0]) || !validIDPrefix(labels[1]) || strings.Join(labels[2:], ".") != domain {
		return "", "", false
	}
	return labels[1], labels[0], true
}

// validIDPrefix reports whether a label is the node id prefix an application host
// carries: eight hex characters, which is what a host is built with and what tells
// one node's applications from another's.
func validIDPrefix(label string) bool {
	return len(label) == appPrefixLength && strings.Trim(label, "0123456789abcdef") == ""
}

// validApplicationDomain reports whether an application host may be built under a
// domain: a name or an address of labels, without a port, because the port is part
// of the origin rather than of the host it is made of.
func validApplicationDomain(domain string) bool {
	if domain == "" || len(domain) > 253 || domain != strings.ToLower(domain) {
		return false
	}
	for _, label := range strings.Split(domain, ".") {
		if !validHostLabel.MatchString(label) {
			return false
		}
	}
	return true
}

// AppAddressing is where a gateway serves the applications of the nodes behind it.
// It is a question rather than a setting because the answer belongs to the shape: a
// gateway that has a domain serves each application on a host of its own under it,
// while one that is only reachable at its own address serves each application on a
// port of its own. Both answer what origin one application of one node is served
// at, because that origin is what a browser keeps one application's storage under,
// and it is where a client is sent when the application is opened.
type AppAddressing interface {
	// Origin returns the origin one application of one node is served at.
	Origin(nodeID, appID string) (string, error)
}

// domainAddressing is the addressing of a gateway that has a domain: every
// application is served on a host of its own under it, and which host that is is
// derived rather than recorded.
type domainAddressing struct {
	domain string
	port   string
}

// addressingFor is how a gateway addresses its applications when it was not told
// otherwise: one host per application under the host its own origin recorded, which
// is what the entrance in front of it issues a certificate for on demand.
func addressingFor(origin string) AppAddressing {
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Hostname() == "" {
		return nil
	}
	return domainAddressing{domain: strings.ToLower(parsed.Hostname()), port: parsed.Port()}
}

func (addressing domainAddressing) Origin(nodeID, appID string) (string, error) {
	host, err := AppHost(nodeID, appID, addressing.domain)
	if err != nil {
		return "", err
	}
	if addressing.port == "" {
		return "https://" + host, nil
	}
	return "https://" + net.JoinHostPort(host, addressing.port), nil
}

// New returns the gateway that serves the nodes a state records. Each node is
// reached at the address that state holds for it, wherever that is — a node on
// another machine in the same network, or the local port a tunnel forwards from
// — and authenticates this gateway with the token held for it. A gateway that
// serves no node is refused: it has nothing to route a request to. Its
// applications are served as hosts under the origin it recorded, which is the
// only place a gateway with a domain puts them; a shape that puts them elsewhere
// says so with SetAppAddressing.
func New(state State, gatewayRoot string) (*Gateway, error) {
	if len(state.Nodes) == 0 {
		return nil, errors.New("a gateway serves no nodes")
	}
	gateway := &Gateway{nodes: slices.Clone(state.Nodes), links: map[string]*nodeLink{}, addressing: addressingFor(state.Origin)}
	if gateway.addressing == nil {
		return nil, errors.New("invalid gateway origin")
	}
	for _, node := range gateway.nodes {
		token, err := ReadNodeToken(gatewayRoot, node.ID)
		if err != nil {
			return nil, err
		}
		link, err := newNodeLink(node, token)
		if err != nil {
			return nil, err
		}
		gateway.links[node.ID] = link
	}
	return gateway, nil
}

// SetAppAddressing tells a gateway where its applications are served, for a shape
// that does not serve them as hosts under the origin it recorded: a LAN entrance
// serves each of them at a port of its own, and a port is the entrance's to
// allocate and to remember. It is said before the gateway serves anything, so no
// application is ever handed out at an origin this gateway does not serve it at.
func (gateway *Gateway) SetAppAddressing(addressing AppAddressing) {
	gateway.addressing = addressing
}

// applicationOrigin is where one application of one node is served, as this
// gateway addresses its applications. A gateway that cannot say is one that cannot
// open an application: there would be nothing to send a client to.
func (gateway *Gateway) applicationOrigin(nodeID, appID string) (string, error) {
	if gateway.addressing == nil {
		return "", errors.New("this gateway addresses no application")
	}
	return gateway.addressing.Origin(nodeID, appID)
}

func newNodeLink(node Node, controlToken string) (*nodeLink, error) {
	target, err := url.Parse("http://" + node.Address)
	if err != nil || target.User != nil || !netaddr.ValidUnicast(target.Host) {
		return nil, errors.New("invalid node address")
	}
	token := strings.TrimSpace(controlToken)
	if !validToken.MatchString(token) {
		return nil, errors.New("invalid control token")
	}
	control := *target
	control.Path = "/__local_remote_control"
	control.RawPath = ""
	control.RawQuery = ""
	proxy := &httputil.ReverseProxy{Rewrite: func(request *httputil.ProxyRequest) {
		// Preserve the public entrance Host. SetURL rewrites it to the loopback
		// node address; apps such as KimiWeb reject WebSocket upgrades when Origin
		// is the public origin but Host is 127.0.0.1 (DNS-rebinding check).
		inboundHost := request.In.Host
		request.SetURL(target)
		request.Out.Host = inboundHost
		request.SetXForwarded()
		proxysecurity.StripInternalHeaders(request.Out.Header)
	}}
	proxy.ModifyResponse = func(response *http.Response) error {
		stripRoutingSetCookie(response.Header)
		return nil
	}
	proxy.ErrorHandler = func(writer http.ResponseWriter, _ *http.Request, _ error) {
		WriteJSON(writer, http.StatusBadGateway, Error("computer_offline"))
	}
	return &nodeLink{
		nodeID: node.ID, controlURL: control.String(), token: token, client: &http.Client{}, application: proxy,
	}, nil
}

// Nodes is every node this gateway serves, in the order they were added.
func (gateway *Gateway) Nodes() []Node {
	return slices.Clone(gateway.nodes)
}

func (link *nodeLink) invoke(action, id string) json.RawMessage {
	payload, err := json.Marshal(map[string]string{"action": action, "id": id})
	if err != nil {
		return nil
	}
	timeout := 7 * time.Second
	if action == "stop" {
		timeout = 20 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, link.controlURL, bytes.NewReader(payload))
	if err != nil {
		return nil
	}
	request.Header.Set("Authorization", "Bearer "+link.token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := link.client.Do(request)
	if err != nil {
		return nil
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil || !json.Valid(body) {
		return nil
	}
	return body
}

// ConnectedList is what one node behind this gateway runs, as that node said it.
// A node this gateway does not serve has no answer to give.
func (gateway *Gateway) ConnectedList(nodeID string) (json.RawMessage, bool) {
	link, ok := gateway.links[nodeID]
	if !ok {
		return nil, false
	}
	return link.connectedList()
}

func validCatalog(value ControlResponse) bool {
	if !value.OK || !value.ComputerConnected || value.Code != "ready" || value.Apps == nil {
		return false
	}
	seen := make(map[string]bool, len(value.Apps))
	for _, app := range value.Apps {
		expected := "stopped"
		if app.Enabled && app.Running {
			expected = "ready"
		} else if app.Enabled {
			expected = "starting"
		} else if app.Running {
			expected = "stopping"
		}
		if !validID.MatchString(app.ID) || seen[app.ID] || !validCatalogMetadata(app.Name, 80, false) || !validCatalogMetadata(app.Description, 240, true) || !validCatalogMetadata(app.Icon, 4, true) || !validAccent.MatchString(app.Accent) || (app.LaunchFragment != "" && (!strings.HasPrefix(app.LaunchFragment, "#") || !validCatalogMetadata(app.LaunchFragment, 2048, false))) || !app.ComputerConnected || app.Code != expected {
			return false
		}
		seen[app.ID] = true
	}
	return true
}

func validCatalogMetadata(value string, maximum int, allowEmpty bool) bool {
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

// list is a node's catalog, or the same offline answer every other endpoint of
// that node gives when it cannot be reached.
func (link *nodeLink) list() json.RawMessage {
	if result, ok := link.connectedList(); ok {
		return result
	}
	encoded, _ := json.Marshal(ControlResponse{OK: true, ComputerConnected: false, Code: "computer_offline", Apps: []ApplicationState{}})
	return encoded
}

// connectedList is what the node answered for its catalog, when this gateway
// understands the answer — every request a client makes about a node goes through
// it, because a catalog this gateway cannot read is a catalog it cannot route.
//
// A node that answered something unreadable is reported here rather than only being
// answered as offline: a client is told the same thing whether that node is off or
// is talking past this gateway, and without this the reason would be visible
// nowhere.
func (link *nodeLink) connectedList() (json.RawMessage, bool) {
	result := link.invoke("list", "")
	if result == nil {
		return nil, false
	}
	var shape ControlResponse
	decoder := json.NewDecoder(bytes.NewReader(result))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&shape) == nil && decoder.Decode(&struct{}{}) == io.EOF && validCatalog(shape) {
		return result, true
	}
	logline.Log("gateway", "warn", "a node answered a catalog this gateway does not understand", "node_id", link.nodeID)
	return result, false
}

func requestPath(request *http.Request) string {
	path := request.URL.Path
	if path == "" {
		return "/"
	}
	return path
}

func writeRaw(writer http.ResponseWriter, body json.RawMessage) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Content-Length", strconv.Itoa(len(body)))
	writer.Header().Set("Cache-Control", "no-store, max-age=0")
	writer.Header().Set("Pragma", "no-cache")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(body)
}

// ServeNode answers one request for one node this gateway serves. Which node a
// request is for is decided where the permission for it is — the trust reads the
// node header, resolves it, and refuses the request otherwise — and what is decided
// there is what arrives here, so this is asked for a node rather than told one by
// the request. A node it does not serve has no route here, and no other node is
// asked instead. An application's own traffic does not arrive here at all: it is
// served at the origin that says which application it is for.
func (gateway *Gateway) ServeNode(nodeID string, writer http.ResponseWriter, request *http.Request) {
	link, ok := gateway.links[nodeID]
	if !ok {
		WriteJSON(writer, http.StatusNotFound, Error("node_not_found"))
		return
	}
	path := requestPath(request)
	// This gateway reaches a node's control plane itself, with the token it holds
	// for that node, and never through the proxy that serves an application: the
	// control plane is this gateway's way in and not part of what a device reaches.
	if path == proxysecurity.ControlPath {
		WriteJSON(writer, http.StatusForbidden, Error("forbidden"))
		return
	}
	if path == "/__remote_everything/apps" && request.Method == http.MethodGet {
		writeRaw(writer, link.list())
		return
	}
	if match := appRoute.FindStringSubmatch(path); match != nil {
		action := match[2]
		validMethod := action == "status" && request.Method == http.MethodGet || (action == "start" || action == "stop") && request.Method == http.MethodPost
		if !validMethod {
			WriteJSON(writer, http.StatusNotFound, Error("not_found"))
			return
		}
		result := link.invoke(action, match[1])
		if result == nil {
			WriteJSON(writer, http.StatusOK, actionResponse{OK: false, Action: action, ComputerConnected: false, Code: "computer_offline"})
			return
		}
		writeRaw(writer, result)
		return
	}
	// Opening an application is what tells a client where to load it from, and what
	// it is told is an origin of that application's own: the application, and the
	// browser storage it owns, is at that origin rather than at this one, which is
	// why nothing is set here that a client would carry back to this gateway. The
	// redirect is the whole of the answer, and it is absolute: a client resolves it
	// against nothing.
	if match := openRoute.FindStringSubmatch(path); match != nil && request.Method == http.MethodGet && validID.MatchString(match[1]) {
		var shape ControlResponse
		_ = json.Unmarshal(link.list(), &shape)
		for _, app := range shape.Apps {
			if app.ID == match[1] {
				origin, err := gateway.applicationOrigin(nodeID, app.ID)
				if err != nil {
					logline.Log("gateway", "error", "application origin unavailable", "node_id", nodeID, "app_id", app.ID, "code", err.Error())
					WriteJSON(writer, http.StatusInternalServerError, Error("internal_error"))
					return
				}
				writer.Header().Set("Location", origin+"/")
				writer.Header().Set("Cache-Control", "no-store")
				writer.WriteHeader(http.StatusFound)
				return
			}
		}
		WriteJSON(writer, http.StatusNotFound, Error("app_not_found"))
		return
	}
	// What is not one of a node's endpoints is not a request this gateway answers
	// here: this origin carries the protocol, and an application is served at an
	// origin of its own rather than at this one.
	WriteJSON(writer, http.StatusNotFound, Error("not_found"))
}

// ServeApplication answers one request on an application's own origin: the
// application that origin names, as the node behind this gateway serves it. Which
// node and which application that is was decided where the origin was read and the
// device's reach was checked, and this is handed the two rather than reading them
// off the request: a client may carry any cookie it likes, and which application a
// browser is looking at is not a client's to decide.
func (gateway *Gateway) ServeApplication(nodeID, appID string, writer http.ResponseWriter, request *http.Request) {
	link, ok := gateway.links[nodeID]
	if !ok {
		WriteJSON(writer, http.StatusNotFound, Error("node_not_found"))
		return
	}
	if !ValidAppID(appID) {
		WriteJSON(writer, http.StatusNotFound, Error("app_not_found"))
		return
	}
	path := requestPath(request)
	// The control plane is the gateway's own way into a node and is never reached
	// through an application's origin, and the protocol's own paths are not part of
	// an application: an origin that serves an application serves that application
	// and nothing else.
	if path == proxysecurity.ControlPath {
		WriteJSON(writer, http.StatusForbidden, Error("forbidden"))
		return
	}
	if strings.HasPrefix(path, "/__remote_everything") {
		WriteJSON(writer, http.StatusNotFound, Error("not_found"))
		return
	}
	setRoutingCookie(request, appID)
	link.application.ServeHTTP(writer, request)
}
