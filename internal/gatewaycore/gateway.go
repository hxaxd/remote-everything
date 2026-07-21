package gatewaycore

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/hxaxd/remote-everything/internal/proxysecurity"
)

var (
	validID     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	validToken  = regexp.MustCompile(`^[a-f0-9]{64}$`)
	validAccent = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
	appRoute    = regexp.MustCompile(`^/__remote_everything/apps/([a-z0-9][a-z0-9._-]{0,63})/(status|start|stop)$`)
	openRoute   = regexp.MustCompile(`^/__remote_everything/open/([a-z0-9][a-z0-9._-]{0,63})$`)
)

type Gateway struct {
	token       string
	controlURL  string
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

func New(nodeURL, controlToken string) (*Gateway, error) {
	target, err := url.Parse(nodeURL)
	if err != nil || target.Scheme != "http" || target.Hostname() != "127.0.0.1" || target.Port() == "" || target.User != nil {
		return nil, errors.New("invalid local node URL")
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
		request.SetURL(target)
		request.Out.Host = request.In.Host
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
	return &Gateway{
		token: token, controlURL: control.String(), client: &http.Client{Timeout: 7 * time.Second}, application: proxy,
	}, nil
}

func (gateway *Gateway) invoke(action, id string) json.RawMessage {
	payload, err := json.Marshal(map[string]string{"action": action, "id": id})
	if err != nil {
		return nil
	}
	request, err := http.NewRequest(http.MethodPost, gateway.controlURL, bytes.NewReader(payload))
	if err != nil {
		return nil
	}
	request.Header.Set("Authorization", "Bearer "+gateway.token)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Accept", "application/json")
	response, err := gateway.client.Do(request)
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

func (gateway *Gateway) ConnectedList() (json.RawMessage, bool) {
	result := gateway.invoke("list", "")
	var shape ControlResponse
	decoder := json.NewDecoder(bytes.NewReader(result))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&shape) == nil && decoder.Decode(&struct{}{}) == io.EOF && validCatalog(shape) {
		return result, true
	}
	return result, false
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

func (gateway *Gateway) List() json.RawMessage {
	if result, ok := gateway.ConnectedList(); ok {
		return result
	}
	encoded, _ := json.Marshal(ControlResponse{OK: true, ComputerConnected: false, Code: "computer_offline", Apps: []ApplicationState{}})
	return encoded
}

func requestPath(request *http.Request) string {
	path := request.URL.EscapedPath()
	if path == "" {
		return "/"
	}
	return path
}

func writeRaw(writer http.ResponseWriter, body json.RawMessage) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Content-Length", strconv.Itoa(len(body)))
	writer.Header().Set("Cache-Control", "no-store, max-age=0")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(body)
}

func (gateway *Gateway) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	path := requestPath(request)
	if path == "/healthz" && request.Method == http.MethodGet {
		WriteJSON(writer, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	if path == "/__local_remote_control" {
		WriteJSON(writer, http.StatusForbidden, Error("forbidden"))
		return
	}
	if path == "/__remote_everything/apps" && request.Method == http.MethodGet {
		writeRaw(writer, gateway.List())
		return
	}
	if match := appRoute.FindStringSubmatch(path); match != nil {
		action := match[2]
		validMethod := action == "status" && request.Method == http.MethodGet || (action == "start" || action == "stop") && request.Method == http.MethodPost
		if !validMethod {
			WriteJSON(writer, http.StatusNotFound, Error("not_found"))
			return
		}
		result := gateway.invoke(action, match[1])
		if result == nil {
			WriteJSON(writer, http.StatusOK, actionResponse{OK: false, Action: action, ComputerConnected: false, Code: "computer_offline"})
			return
		}
		writeRaw(writer, result)
		return
	}
	if match := openRoute.FindStringSubmatch(path); match != nil && request.Method == http.MethodGet && validID.MatchString(match[1]) {
		var shape ControlResponse
		_ = json.Unmarshal(gateway.List(), &shape)
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
	gateway.application.ServeHTTP(writer, request)
}
