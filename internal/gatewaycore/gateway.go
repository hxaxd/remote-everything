package gatewaycore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
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
)

// Gateway is the control plane of every node one gateway serves: each node is
// reached at the address this gateway recorded for it and authenticates it with
// that node's own token. It is asked for one of them at a time — which node a
// request is for is decided where the permission for it is, and a gateway routes
// what it was asked to route rather than reading that off the request again.
type Gateway struct {
	nodes []Node
	links map[string]*nodeLink
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

// New returns the gateway that serves the nodes a state records. Each node is
// reached at the address that state holds for it, wherever that is — a node on
// another machine in the same network, or the local port a tunnel forwards from
// — and authenticates this gateway with the token held for it. A gateway that
// serves no node is refused: it has nothing to route a request to.
func New(state State, gatewayRoot string) (*Gateway, error) {
	if len(state.Nodes) == 0 {
		return nil, errors.New("a gateway serves no nodes")
	}
	gateway := &Gateway{nodes: slices.Clone(state.Nodes), links: map[string]*nodeLink{}}
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
// asked instead.
func (gateway *Gateway) ServeNode(nodeID string, writer http.ResponseWriter, request *http.Request) {
	link, ok := gateway.links[nodeID]
	if !ok {
		WriteJSON(writer, http.StatusNotFound, Error("node_not_found"))
		return
	}
	path := requestPath(request)
	// This gateway reaches a node's control plane itself, with the token it holds
	// for that node. An application's traffic leaves through the proxy below and the
	// control plane never travels in it, whichever node it is addressed to.
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
	// Opening an application is what says which one this browser session is looking
	// at, not what a device may reach: a device reaches every application of a node
	// it holds, and this is the cookie that picks between them.
	if match := openRoute.FindStringSubmatch(path); match != nil && request.Method == http.MethodGet && validID.MatchString(match[1]) {
		var shape ControlResponse
		_ = json.Unmarshal(link.list(), &shape)
		for _, app := range shape.Apps {
			if app.ID == match[1] {
				http.SetCookie(writer, &http.Cookie{Name: proxysecurity.RoutingCookieName, Value: match[1], Path: "/", MaxAge: 86400, Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
				writer.Header().Set("Location", "/")
				writer.Header().Set("Cache-Control", "no-store")
				writer.WriteHeader(http.StatusFound)
				return
			}
		}
		WriteJSON(writer, http.StatusNotFound, Error("app_not_found"))
		return
	}
	if strings.HasPrefix(path, "/__remote_everything") {
		WriteJSON(writer, http.StatusNotFound, Error("not_found"))
		return
	}
	link.application.ServeHTTP(writer, request)
}
