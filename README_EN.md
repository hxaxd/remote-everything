<div align="center">

# Remote Everything

**Bring local Web apps on your computers securely to every mobile device.**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=for-the-badge)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hxaxd/remote-everything?style=for-the-badge)](https://github.com/hxaxd/remote-everything/releases)
[![Clients](https://img.shields.io/badge/clients-Android%20·%20iOS%20·%20HarmonyOS-7c3aed?style=for-the-badge)](#supported-platforms)
[![Nodes](https://img.shields.io/badge/nodes-Windows%20·%20Linux%20·%20macOS-059669?style=for-the-badge)](#supported-platforms)

[中文](README.md) · **English**

[Overview](#overview) · [Highlights](#highlights) · [Quick start](#quick-start) · [Security model](#security-model) · [Contributing](#contributing)

</div>

## Overview

KimiWeb, SillyTavern, CloudCLI, Pi Chat, and the small tools you build live on your computers, but you do not have to stay in front of them.

Remote Everything runs a lightweight node on each computer and presents explicitly registered local Web apps in native Android, iOS, and HarmonyOS clients. It does not modify those apps, move their data to a third-party cloud, or require a new account system: connect directly on the same network, or remotely through your own server or existing overlay network.

> One mobile client connects to many computers; one computer instance manages many local apps.

## Highlights

- 🚀 **Scan and connect**: install the client, scan a QR code, and verify a fingerprint—no addresses, ports, passwords, or tokens to type.
- 📱 **Three native clients**: Android, iOS, and HarmonyOS share one protocol and product structure while retaining each platform's native security and Web-container capabilities.
- 🖥️ **Three node platforms**: Windows, Linux, and macOS run in the user's login session and reap managed app process trees on exit.
- 🔐 **Device-level trust**: public devices require a single-use invitation, certificate request, full-fingerprint confirmation, and mTLS activation.
- 🌐 **LAN and remote access**: connect directly over LAN or an existing overlay; public mode reuses port 443 on your server through Caddy and FRP.
- 🧭 **Multiple computers**: every computer has an independent installation ID; clients store and switch between Profiles without coupling their failures.
- 🧩 **Apps fit naturally**: KimiWeb, SillyTavern, CloudCLI, and Pi Chat are adapted; other local Web apps use the same strict definition.
- 🗂️ **Isolated sessions**: Android and iOS keep persistent data isolated per installation and app; HarmonyOS clears incognito data when switching apps so sessions cannot leak across them.
- 🔄 **Trusted updates**: clients show their version and project link; Android verifies release digests, package identity, and signing, while iOS and HarmonyOS use their official distribution channels.
- 🤖 **Agent-driven operations**: executable Skills cover installation, app onboarding, device pairing, inspection, upgrades, and removal.

## Supported platforms

| Category | Support |
|---|---|
| Mobile clients | Android · iOS · HarmonyOS |
| Computer nodes | Windows · Linux · macOS |
| Access modes | LAN / overlay network · Linux public gateway |
| Adapted apps | KimiWeb · SillyTavern · CloudCLI · Pi Chat |
| Multiple computers | One independent instance per computer, multiple client Profiles |

## How it works

```text
Android / iOS / HarmonyOS
          │
          │ HTTPS (LAN certificate pinning / public mTLS)
          ▼
     LAN entry or public Gateway
          │
          │ internal control token + constrained reverse proxy
          ▼
 Windows / Linux / macOS Node
          │
          ├── KimiWeb
          ├── SillyTavern
          ├── CloudCLI
          ├── Pi Chat
          └── other loopback Web apps
```

One computer maps to one Node, one Gateway, one `installationId`, and one client Profile. In public deployments, gateways for several computers may share one Caddy listener on port 443, while identities, ports, device records, and runtime state remain independent.

## Quick start

### 1. Get the project

```bash
git clone https://github.com/hxaxd/remote-everything.git
cd remote-everything
```

### 2. Install a mobile client

Android can use the signed APK from the current [Release](https://github.com/hxaxd/remote-everything/releases). When no official distribution channel is listed, iOS must be built and signed with the user's own development identity through Xcode/XcodeGen on macOS, and HarmonyOS must be built with DevEco Studio and the user's own debug signing configuration. See the [client acquisition guide](skills/remote-everything-install/references/mobile-clients.md).

### 3. Let an agent deploy it

Tell the agent working in this repository:

```text
Deploy Remote Everything for me
```

Choose LAN or remote access, scan the QR code, and—in public mode—verify the complete device fingerprint. The installation Skill handles nodes, dynamic ports, certificates, service managers, and runtime records.

Everyday operations use plain language as well:

- `Add the XX app on this machine to Remote Everything`
- `Pair this mobile device`
- `Inspect the current deployment`
- `Upgrade to the latest release`
- `Uninstall and clean the runtime environment`

## Security model

- **LAN**: before opening a remote app, the client verifies the gateway with the server-certificate SHA-256 fingerprint from the QR code and also checks certificate validity and target host. The entry is limited to the selected LAN or overlay interface.
- **Public**: pairing invitations are single-use and time-limited. Device certificates remain pending until the user verifies the full fingerprint and approves them; subsequent requests require both mTLS and an active device record.
- **Server side**: the gateway-to-node control token never enters a mobile client or release package. Public deployments add traffic only to the existing port 443 entry.
- **Client side**: device credentials live in system secure storage. Web data uses the strongest verifiable isolation available on each platform, and external links are handed to the system browser.
- **Supply chain**: release assets include SHA-256 digests. Stable clients use a pinned project signature or official platform distribution signing, and both the local release gate and optional CI reject packaged deployment credentials.

Do not open a public Issue for a vulnerability. Follow the private process in the [Security Policy](SECURITY.md).

## Good use cases

- Continue a KimiWeb session from a home or office computer while commuting.
- Use local SillyTavern from a mobile device with an isolated persistent session.
- Check CloudCLI sessions and other self-hosted tools from anywhere.
- Continue coding sessions in Pi Chat from a mobile device.
- Manage computers running different operating systems without exposing every application's raw port.

## Contributing

```text
clients/   three mobile clients and shared contracts
nodes/     Windows / Linux / macOS nodes
server/    LAN entry and public gateway
internal/  shared Go core
apps/      adapted applications
skills/    executable operational workflows
```

- [Contributing Guide](CONTRIBUTING.md)
- [Support](SUPPORT.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)

## FAQ

<details>
<summary><strong>Do I need a public IP or domain?</strong></summary>

No. Use the LAN entry on the same network. For remote access, reuse an existing overlay network or use your own Linux public server. Public servers normally use a domain, while other HTTPS entries are possible when they satisfy the certificate requirements.
</details>

<details>
<summary><strong>How many clients do I install on a mobile device?</strong></summary>

Install one universal client for that device's operating system. It can store Profiles for multiple computers and access every app registered on each computer.
</details>

<details>
<summary><strong>Do I need to pair again after a computer is powered off?</strong></summary>

No. The catalog shows the computer as offline and reconnects when the node returns. Re-pairing is only needed when credentials are revoked, certificates are renewed, or the instance is rebuilt.
</details>

<details>
<summary><strong>Does traffic pass through a server operated by this project?</strong></summary>

No. Traffic stays between your mobile devices, computers, LAN/overlay, and your own public server.
</details>

<details>
<summary><strong>What does it cost?</strong></summary>

The project is free and open source under Apache-2.0. You only pay for infrastructure or network services you choose yourself.
</details>

## License

[Apache License 2.0](LICENSE)
