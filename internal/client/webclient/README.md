# Browser connections

Pairing always consumes a fresh, single-use invitation. A browser identifier only
names its device record; it cannot authorize pairing or obtain access credentials.

Each browser connection has three independent random credentials:

- Access token: authorizes requests through the gateway. Application handoffs share
  this connection, so all application cookies are revoked together.
- Unlock token: encrypted locally with the browser password; its hash is stored by
  the gateway. Unlock replaces the access token and cancels the previous token.
- Revocation token: permits only locking or logout. It is stored alongside the
  encrypted vault so reload and forgotten-password flows can still revoke access.

Lock clears access, unused handoff tickets, and active HTTP/WebSocket connections.
Logout additionally removes the gateway's unlock credential and the local vault.
Opening or reloading the control page locks the connection; other control tabs
receive the lock/logout event. Network or persistence errors are surfaced to the user.

The connection expires 30 days after pairing. Unlock and application handoffs do
not extend that deadline. A handoff ticket is single-use and expires after one minute;
redemption sets the application cookie then redirects to a URL without the ticket.
Access and revocation are isolated to this gateway and browser connection.

These credentials belong to the gateway. Applications may have their own login
cookies, but those cannot bypass the gateway after its access token is revoked.
Application requests receive neither gateway cookies nor gateway credential headers.

Run the checks described in [tests/README.md](tests/README.md).

## Public application cookie boundary

The public entrance uses a `__Host-` prefixed, Secure, HttpOnly session cookie with
Path=/ and no Domain. Only that name authorizes cookie-based public access. Gateway
credentials are filtered before forwarding to applications, and applications cannot
set either reserved gateway cookie name.

Public application `Set-Cookie` responses are parsed, confined to the current host,
and marked Secure. Cookie names, values, paths, expiry, SameSite, HttpOnly and
Partitioned semantics are retained; malformed cookies are discarded. The response
policy also runs for redirects and protocol upgrades.

Application trust requirements and the limits of these response filters are
defined in the [application trust boundary](../../skills/remote-everything-app/SKILL.md#应用信任边界).
