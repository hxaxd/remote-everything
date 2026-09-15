# Remote Everything Protocol Contracts

This directory holds the shared wire-format contracts used by all four platforms (Go server, Android, iOS, HarmonyOS).

## Directory Layout

```
contracts/
├── schemas/          # JSON Schema definitions (human-readable contracts)
│   ├── setup-uri.schema.json
│   ├── catalog.schema.json
│   ├── pairing.schema.json
│   ├── activation.schema.json
│   ├── control.schema.json
│   └── release.schema.json
└── README.md
```

## How to Use

JSON Schemas are **human-readable documentation** of the wire format. They describe field names, types, patterns, and conditional constraints (e.g., LAN mode requires `fingerprint`, public mode requires `invitation`).

**Do NOT use schemas for runtime validation.** Each platform implements its own strict decoder in its native language, and every platform's test suite exercises that decoder directly with inline payloads (see `internal/setup` in Go, and each client's parser tests). Schemas exist so reviewers can verify that all four decoders enforce the same rules.

## Contract Drift

If a platform needs to "correct" a server response differently from the others, that is **contract drift**. The fix must either:
- Update the schema (if the contract has changed), or
- Fix the platform's decoder and its tests (if the platform is wrong)

A platform must never silently accept what another platform rejects, or vice versa.

## Versioning

The `protocolVersion` field in `clients/release.json` governs wire compatibility. When it increments, all previous pairings are invalidated and clients must re-pair.
