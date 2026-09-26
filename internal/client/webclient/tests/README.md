# Browser checks

Run `node internal/client/webclient/tests/browser.cjs` with an installed `playwright`
package. Set `PLAYWRIGHT_MODULE` to its absolute package directory if it is not
available in the current module search path. `BROWSER_CHANNEL` defaults to
`msedge`; `WEB_TEST_OUTPUT` defaults to `dist/web-redesign`.

The runner serves the actual embedded files on an ephemeral loopback port and
supplies catalog and session API fixtures. It verifies pairing and validation,
approval after reload, encrypted storage and unlock, application actions and
failures, authenticated opening with a launch fragment, node-switch races,
search, offline and empty states, session expiry, logout, theme selection, and
mobile overflow. Screenshots cover desktop, mobile, and dark appearance.

Run `go test ./internal/client/webclient ./server/lan ./server/public` for real gateway
pairing, device admission, application proxying, and single-use handoff tickets.

Session checks cover deny-only revocation credentials, encrypted unlock credentials,
failed lock feedback, cross-tab locking, reload revocation, and logout persistence.
The Go lifecycle tests verify fixed expiry, restart persistence, ticket/revocation
races, device revocation, and active HTTP streaming and WebSocket disconnection.
LAN and public gateway tests exercise application cookies across lock/unlock/logout.
