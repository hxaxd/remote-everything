// DSH adapter: extracts the launch token from stdout and injects it
// into every proxied request as a query parameter.
//
// DSH 0.1.5+ generates a random token on startup and prints a URL
// containing it (e.g. http://127.0.0.1:PORT/?token=xxx). Without this
// adapter, the remote proxy cannot know the token, causing 401 errors.

function onStart() {
    var m = __stdout.match(/token=([a-f0-9]+)/);
    if (m) {
        __state.set("token", m[1]);
    }
}

function onRequest() {
    var t = __state.get("token");
    if (t) {
        __req.setQuery("token", t);
    }
}
