// Package proxysecurity is the boundary between the deployment's own traffic and
// an application's: the names it reserves, and the one place that says which
// headers those are.
package proxysecurity

import "net/http"

const RoutingCookieName = "RemoteEverythingApp"

// WebSessionCookieName is the cookie a gateway sets to carry its web client's
// session. It belongs to this deployment and not to any application — the
// session is how the gateway knows who the browser is — so it is named here
// with the routing cookie: an application never sees it set, sent or
// rewritten, the same as it never sees the headers below.
const WebSessionCookieName = "remote_everything_web"

// ControlPath is where a node answers its own control plane. Only the gateway that
// serves it reaches that, with the token it holds for it, and it never travels
// through the proxy that serves an application: one path, named once, because the
// gateway refuses it and the node answers it.
const ControlPath = "/__local_remote_control"

// The headers a gateway and its device trust keep to themselves, and that an
// application never sees. Each one is named here so that the code that sets it,
// the code that reads it and the list below cannot drift apart.
const (
	// ClientFingerprintHeader speaks for a device: it is the fingerprint of the
	// certificate the entrance verified, and whatever the client claimed for
	// itself was dropped before it was set.
	ClientFingerprintHeader = "X-Remote-Everything-Client-Fingerprint"
	// NodeHeader names the node a request is for: a gateway serves several, and
	// this is what says which one answers. It is read once, where the permission
	// for that node is decided, and what is decided there is handed on.
	NodeHeader = "X-Remote-Everything-Node"
)

var internalHeaderNames = [...]string{
	ClientFingerprintHeader,
	NodeHeader,
}

func StripInternalHeaders(header http.Header) {
	for _, name := range internalHeaderNames {
		header.Del(name)
	}
}
