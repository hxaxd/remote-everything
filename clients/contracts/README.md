# Remote Everything Protocol Contracts

This directory describes the wire between a client, a gateway and a node: what a client is given, what it sends, and what it is answered with. It is the **specification of the protocol as the server speaks it today** — written from the running code, not from what any client once did.

The three client implementations in this repository speak this protocol: each parses the setup URI of `setup-uri.schema.json` (no version, no installation id, no mode on the wire) and calls the endpoints in the table below. The Go side in `internal/` is the reference, and the schemas are how a reviewer checks that a client agrees with it.

## Directory Layout

```
contracts/
├── schemas/          # JSON Schema definitions (human-readable contracts)
│   ├── setup-uri.schema.json   # what an invitation carries
│   ├── pairing.schema.json     # redeeming it for a credential
│   ├── activation.schema.json  # being admitted, for one node
│   ├── nodes.schema.json       # which nodes this device may reach
│   ├── catalog.schema.json     # what one node runs
│   ├── control.schema.json     # status, start and stop
│   ├── errors.schema.json      # every refusal
│   └── release.schema.json     # clients/release.json itself
└── README.md
```

## The wire

Every path below is relative to the `origin` an invitation carries, over HTTPS, with the device credential of step 2 presented as the client certificate.

| # | Request | Credential | Names a node | Answered with |
|---|---------|------------|--------------|---------------|
| 1 | `POST /__remote_everything_pair` | none — carries `Authorization: Invitation <token>` | no | `pairing.schema.json` |
| 2 | `POST /__remote_everything_activate` | device certificate | yes | `activation.schema.json` |
| 3 | `GET /__remote_everything/nodes` | device certificate | **no** | `nodes.schema.json` |
| 4 | `GET /__remote_everything/apps` | device certificate | yes | `catalog.schema.json` |
| 5 | `GET /__remote_everything/apps/:id/status` | device certificate | yes | `control.schema.json` |
| 6 | `POST /__remote_everything/apps/:id/start` | device certificate | yes | `control.schema.json` |
| 7 | `POST /__remote_everything/apps/:id/stop` | device certificate | yes | `control.schema.json` |
| 8 | `GET /__remote_everything/open/:id` | device certificate | yes | `302` to the application's own origin |
| 9 | everything else, **on the application's own origin** | device certificate | no — the origin says which application | the node's own application |

Two things about that table are the protocol:

- **A gateway serves several nodes, so a request says which one it is for**, in the `X-Remote-Everything-Node` header, carrying the node id from the invitation or from step 3. A request that names no node, a node this gateway does not serve, and a node this device was not granted are all answered `401` — the same answer for the last two, so a device cannot learn which nodes exist by asking about them.
- **Step 3 is the one request that names no node.** It is how a device asks what it has, so requiring it to know a node id first would be requiring the answer to ask the question. It is also how a device learns about a node granted to it after it paired, which is why granting one is not a re-pairing.
- **Step 8 answers with the application's own origin, and step 9 happens there.** Every application of every node is served on an origin of its own — on a gateway with a domain, `<appid>.<node-prefix>.<gateway-domain>`; on a LAN gateway, a port of its own on the gateway's address — and that origin is what makes one application's browser storage invisible to every other. The `Location` is absolute; a client resolves it against the gateway origin and loads it. It carries no cookie: which application the WebView is looking at is said by the origin, and the gateway tells the node so on the way through. The redirect to an origin is stable for the life of the application: coming back to the same application comes back to the same origin, and its storage is still there.

A refusal is always the body in `errors.schema.json`, with the code naming what was refused; the HTTP status says the same thing again for proxies and logs. A node that is off is an *answer* (`computer_offline`), not a refusal — except where a refusal carries information the client needs, as `approval_pending` does at HTTP 202.

## How to Use

JSON Schemas are **human-readable documentation** of the wire format: field names, types, patterns, and the constraints that hold between fields. Where two endpoints answer with the same body, one schema says so by referencing the other rather than describing it twice.

**Do NOT use schemas for runtime validation.** Each implementation decodes strictly in its own language — on the Go side `internal/protocol/setup`, `internal/gateway/gatewaycore` and `internal/gateway/devicecore` — and rejects a body it does not understand rather than tolerating it. Schemas exist so a reviewer can check that an implementation enforces the same rules, and so the next client has one document to implement against.

## Contract Drift

An implementation that "corrects" a server response differently from the others is **contract drift**, and it is a bug in one of the two. The fix must either update the schema (the contract changed) or fix the implementation (it is wrong).

An implementation must never silently accept what another rejects, or vice versa. The stricter reading wins, and if the schema is the looser one, the schema is what gets fixed.

## Versioning

`protocolVersion` in `clients/release.json` is `1`: this is the first protocol this project speaks, so there is nothing earlier to stay compatible with. There is no negotiation and no compatibility path — a client either speaks this protocol, or it is paired again with a freshly issued invitation.
