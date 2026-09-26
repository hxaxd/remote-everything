package devicecore

import (
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"slices"
	"strings"

	"github.com/hxaxd/remote-everything/internal/gateway/gatewaycore"
	"github.com/hxaxd/remote-everything/internal/infra/netaddr"
	"github.com/hxaxd/remote-everything/internal/protocol/wire"
)

// TLSAskPath is where the entrance in front of a public gateway asks, before it
// issues a certificate, whether one more application host is one this gateway
// serves. The entrance asks it on the address it forwards everything else to,
// without a device credential of its own — it has none, it is not a device — and
// the path is one name here and in the template that renders that entrance.
const TLSAskPath = "/__remote_everything_tls_ask"

// AppHandler answers what an application's own origin carries: one application of
// one node, for a device this gateway admitted and granted that node. Which node
// and which application those are is what the origin of the request said, and
// where that origin was read — the host an entrance in front resolved, the port
// this gateway allocated — is what this is told, because a request cannot name
// them any other way: anything it carries could be chosen by whoever sent it.
func (service *Trust) AppHandler(nodeID, appID string) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		record, ok := service.authorizedDevice(request)
		if !ok || !slices.Contains(record.Nodes, nodeID) {
			// A device this gateway never admitted and one that does not hold this
			// node are answered the same way, for the reason every other refusal in
			// this protocol is: which nodes exist is not something a device learns by
			// asking about the ones it cannot reach.
			gatewaycore.WriteJSON(writer, http.StatusUnauthorized, gatewaycore.Error("unauthorized"))
			return
		}
		service.node.ServeApplication(nodeID, appID, writer, request)
	})
}

// applicationDomain is the host this gateway serves its applications under: the
// host part of the origin it recorded, which is what the entrance in front of it
// issues one certificate per application for.
func (service *Trust) applicationDomain() string {
	parsed, err := url.Parse(service.origin)
	if err != nil {
		return ""
	}
	return strings.ToLower(parsed.Hostname())
}

// answerTLSPermission answers the entrance in front of this gateway, which asks
// whether one more application host may have a certificate before it issues one.
// It is the only question answered without a device credential — the entrance has
// no device to show, and what it is asking about is not a device's — and that is
// also why only this machine may ask it: the entrance stands in front of this
// gateway here, and an answer given to anyone else would be this gateway lending
// its word about itself to whoever asked for it.
//
// A host is allowed when it is an application host of this gateway's own domain,
// names a node this gateway serves right now, and that node runs that application.
// A node that is off answers no — its applications cannot be opened while it is —
// and so does an application it does not run: what the entrance is told is what it
// will have a certificate for, so it is told what is served rather than what could
// be asked for.
func (service *Trust) answerTLSPermission(writer http.ResponseWriter, request *http.Request) {
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	if request.Method != http.MethodGet || err != nil || !netaddr.ValidLoopbackHost(host) ||
		!service.applicationHostIsServed(request.URL.Query().Get("domain")) {
		gatewaycore.WriteJSON(writer, http.StatusForbidden, gatewaycore.Error("forbidden"))
		return
	}
	gatewaycore.WriteJSON(writer, http.StatusOK, map[string]bool{"ok": true})
}

// applicationHostIsServed reports whether this gateway serves the host the
// entrance asks about: an application host of this gateway's domain, for a node it
// serves and an application that node answers for. The node is asked, so a node
// that is off is a host nothing reaches rather than one that is served on paper.
func (service *Trust) applicationHostIsServed(host string) bool {
	prefix, appID, ok := gatewaycore.ParseAppHost(host, service.applicationDomain())
	if !ok {
		return false
	}
	node, ok := gatewaycore.NodeByPrefix(service.node.Nodes(), prefix)
	if !ok {
		return false
	}
	apps, connected := service.node.ConnectedList(node.ID)
	if !connected {
		return false
	}
	var catalog wire.Catalog
	if json.Unmarshal(apps, &catalog) != nil {
		return false
	}
	for _, app := range catalog.Apps {
		if app.ID == appID {
			return true
		}
	}
	return false
}
