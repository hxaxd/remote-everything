// DSH adapter: extracts the launch token from stdout and injects it
// into proxied requests until the client has acquired the dsh-auth session cookie.
//
// DSH 0.1.5+ generates a random token on startup and prints a URL
// containing it (e.g. http://127.0.0.1:PORT/?token=xxx). When accessed
// with ?token=xxx, DSH mints a dsh-auth-* session cookie and redirects
// to clean /. If ?token= is continuously injected after the cookie is set,
// DSH continuously redirects to /, causing an infinite 303 loop.

function onStart() {
    var m = __stdout.match(/token=([A-Za-z0-9_-]+)/);
    if (m) {
        __state.set("token", m[1]);
    }
}

// DSH was started with --trusted-host naming exactly one origin, and it answers API
// calls by that name only: a phone that reaches this node by any other name — the LAN
// entrance's own address, a new gateway origin — gets the page shell and a 403 on every
// action. The node hands the entrance's Host to the application on purpose (apps that
// compare Origin against Host need it), so the one app that has an allow-list asks for
// the name it knows here. Rendering fills in that name, which is the same value the
// definition passes to --trusted-host; a new entrance therefore needs no re-registration.
var CANONICAL_HOST = "{{TRUSTED_HOST}}";

/** The same URL said in the name DSH knows, whatever road it came in on. */
function inCanonicalName(value) {
    var m = value.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/[^\/]+(\/.*)?$/);
    return m ? "https://" + CANONICAL_HOST + (m[2] || "/") : value;
}

function onRequest() {
    if (__req.setHeader) {
        __req.setHeader("Host", CANONICAL_HOST);
        var origin = __req.getHeader ? __req.getHeader("Origin") : "";
        if (origin) {
            __req.setHeader("Origin", inCanonicalName(origin));
        }
        var referer = __req.getHeader ? __req.getHeader("Referer") : "";
        if (referer) {
            __req.setHeader("Referer", inCanonicalName(referer));
        }
    }
    var t = __state.get("token");
    if (!t) {
        return;
    }
    var cookie = "";
    if (__req.getHeader) {
        cookie = __req.getHeader("Cookie") || __req.getHeader("cookie") || "";
    }
    if (cookie.indexOf("dsh-auth-") === -1) {
        __req.setQuery("token", t);
    }
}

