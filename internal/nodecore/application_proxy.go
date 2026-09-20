package nodecore

import (
	"html"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"

	"github.com/hxaxd/remote-everything/internal/proxysecurity"
	"github.com/hxaxd/remote-everything/internal/wire"
)

func (node *Node) selectedApplication(request *http.Request) (AppDefinition, error) {
	cookie, err := request.Cookie(proxysecurity.RoutingCookieName)
	if err != nil || !wire.ValidAppID(cookie.Value) {
		return AppDefinition{}, os.ErrNotExist
	}
	app, err := node.findApp(cookie.Value)
	if err != nil {
		return AppDefinition{}, err
	}
	if !node.isEnabled(app.ID) && probeOpen(probeAddress(app)) {
		return AppDefinition{}, os.ErrNotExist
	}
	return app, nil
}

func removeRoutingCookie(request *http.Request) {
	values := make([]string, 0)
	for _, cookie := range request.Cookies() {
		if cookie.Name != proxysecurity.RoutingCookieName {
			values = append(values, cookie.Name+"="+cookie.Value)
		}
	}
	request.Header.Del("Cookie")
	if len(values) > 0 {
		request.Header.Set("Cookie", strings.Join(values, "; "))
	}
}

// gatewayMessage answers a request that reached the node without an application
// to serve it. The page is deliberately bare: a client that addresses a node
// directly is not the way in — the gateway decides which application a request
// is for and says so on the request it forwards — so this is a fallback, and it
// looks like one rather than like an interface of its own.
func gatewayMessage(writer http.ResponseWriter, status int, title, detail string) {
	title = html.EscapeString(title)
	detail = html.EscapeString(detail)
	body := "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta name=\"color-scheme\" content=\"dark light\"><title>" + title + "</title><body><p>" + title + "</p><p>" + detail + "</p></body></html>"
	writer.Header().Set("Content-Type", "text/html; charset=utf-8")
	writer.Header().Set("Cache-Control", "no-store")
	writer.WriteHeader(status)
	_, _ = writer.Write([]byte(body))
}

func (node *Node) gatewayHandler(writer http.ResponseWriter, request *http.Request) {
	if request.URL.Path == proxysecurity.ControlPath {
		node.localControlHandler(writer, request)
		return
	}
	app, err := node.selectedApplication(request)
	if err != nil {
		gatewayMessage(writer, http.StatusOK, "尚未选择远程应用", "请从远程万物手机客户端的应用目录进入。")
		return
	}
	target, _ := url.Parse(app.ProxyURL)
	removeRoutingCookie(request)
	proxysecurity.StripInternalHeaders(request.Header)
	// Preserve the entrance Host across the node→app hop. Gateway already keeps the
	// public/LAN Host; NewSingleHostReverseProxy would rewrite it to 127.0.0.1:port and
	// break apps (e.g. KimiWeb) that compare Origin against Host for DNS rebinding.
	inboundHost := request.Host
	// Look up adapter for this app (nil if none configured)
	node.adaptersMu.RLock()
	adapter := node.adapters[app.ID]
	node.adaptersMu.RUnlock()
	proxy := &httputil.ReverseProxy{
		Rewrite: func(proxyRequest *httputil.ProxyRequest) {
			proxyRequest.SetURL(target)
			proxyRequest.Out.Host = inboundHost
			if adapter != nil {
				adapter.OnRequest(proxyRequest.Out, app.ID)
			}
		},
	}
	if adapter != nil {
		proxy.ModifyResponse = func(resp *http.Response) error {
			adapter.OnResponse(resp, app.ID)
			return nil
		}
	}
	proxy.ErrorHandler = func(responseWriter http.ResponseWriter, _ *http.Request, _ error) {
		gatewayMessage(responseWriter, http.StatusBadGateway, app.Name+" 尚未运行", "请返回应用目录启动它，然后重新进入。")
	}
	proxy.ServeHTTP(writer, request)
}
