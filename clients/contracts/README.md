# Remote Everything Protocol Contracts

This directory holds the shared protocol contracts and test fixtures used by all four platforms (Go server, Android, iOS, HarmonyOS). They are the single source of truth for API shapes and validation rules.

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
├── fixtures/
│   ├── valid/        # Payloads that every platform MUST accept
│   └── invalid/      # Payloads that every platform MUST reject
└── README.md
```

## How to Use

### Schemas

JSON Schemas serve as **human-readable documentation** of the contract. They describe field names, types, patterns, and conditional constraints (e.g., LAN mode requires `fingerprint`, public mode requires `invitation`).

**Do NOT use schemas for runtime validation.** Each platform must implement its own strict decoder in its native language. Schemas exist so reviewers can verify that all four decoders enforce the same rules.

### Fixtures

Fixture files contain concrete JSON payloads (and, for setup URIs, the raw URI string). Every platform's test suite reads from the same fixture files:

- **Go** tests read from `../../clients/contracts/fixtures/`
- **Android** tests read from `../../contracts/fixtures/` (relative to `clients/android/app/src/test/resources/`)
- **iOS** tests bundle fixtures via Xcode test resources
- **HarmonyOS** tests reference fixtures via test resource paths

### Adding a Fixture

1. Add the JSON file to `valid/` or `invalid/` with a `description` field explaining the scenario.
2. Optionally include an `error` field with a symbolic error code (used by test assertions).
3. Run all four platform tests to confirm consistent behavior.

### Contract Drift

If a platform needs to "correct" a server response differently from the others, that is **contract drift**. The fix must either:
- Update the fixture (if the fixture was wrong), or
- Update the schema (if the contract has changed), or
- Fix the platform's decoder (if the platform is wrong)

A platform must never silently accept what another platform rejects, or vice versa.

## Versioning

The `protocolVersion` field in `clients/release.json` governs wire compatibility. When it increments, all previous pairings are invalidated and clients must re-pair.
