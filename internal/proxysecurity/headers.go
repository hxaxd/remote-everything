package proxysecurity

import "net/http"

const RoutingCookieName = "RemoteEverythingApp"

var internalHeaderNames = [...]string{
	"X-Remote-Everything-Client-Fingerprint",
	"X-Remote-Everything-Control-Token",
}

func StripInternalHeaders(header http.Header) {
	for _, name := range internalHeaderNames {
		header.Del(name)
	}
}
