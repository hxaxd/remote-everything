<div align="center">

# Remote Everything

**Bring the local Web apps on your computer securely onto your mobile device.**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=for-the-badge)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hxaxd/remote-everything?style=for-the-badge)](https://github.com/hxaxd/remote-everything/releases)
[![Clients](https://img.shields.io/badge/clients-Android%20·%20iOS%20·%20HarmonyOS-7c3aed?style=for-the-badge)](#supported-scope)
[![Nodes](https://img.shields.io/badge/nodes-Windows%20·%20Linux%20·%20macOS-059669?style=for-the-badge)](#supported-scope)

[中文](README.md) · **English**

[Introduction](#introduction) · [Core capabilities](#core-capabilities) · [Quick start](#quick-start) · [Security model](#security-model) · [Contributing](#contributing)

</div>

## Introduction

DSH (DeepSeek Harness), SillyTavern, and the small tools you write all run on your computer—but you do not have to stay in front of it.

Remote Everything runs a lightweight node on the computer and delivers explicitly registered local Web apps to Android, iOS, or HarmonyOS clients. It does not modify the original apps or move data to a third-party cloud: connect directly on the same network, or remotely through your own server or existing overlay network.

> One mobile client connects to many computers; one computer instance manages many local apps.

## Core capabilities

- 🚀 **Scan to connect**: install the client, scan a QR code, verify the fingerprint—no addresses, ports, passwords, or tokens to type by hand.
- 📱 **Three native clients**: Android, iOS, and HarmonyOS share the same protocol and product structure, while keeping each platform's native security and Web-container capabilities.
- 🖥️ **Three desktop nodes**: Windows, Linux, and macOS run in the user's login session and reap managed app process trees on logout.
- 🔐 **Device-level trust**: public devices require a single-use invitation, certificate request, full-fingerprint human confirmation, and mTLS activation.
- 🌐 **LAN and remote**: access over LAN or an existing overlay; public mode reuses server port 443, with Caddy and FRP as the controlled entry.
- 🧭 **Switch among computers**: each computer has an independent ID; the client manages and switches Profiles without coupling them.
- 🧩 **Apps ready to plug in**: DSH (DeepSeek Harness) and SillyTavern are adapted; other local Web apps can use the same definition.
- 🤖 **Agent-driven operations**: installation, app onboarding, device pairing, inspection, upgrades, and removal all have executable Skills—no handwritten deploy notes required.

## Supported scope

| Category | Support |
|---|---|
| Mobile clients | Android · iOS · HarmonyOS |
| Computer nodes | Windows · Linux · macOS |
| Access modes | LAN / overlay network · Linux public gateway |
| Adapted apps | DSH (DeepSeek Harness) · SillyTavern |
| Multiple computers | Independent instance per computer; multi-Profile switching on the client |

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
          ├── DSH (DeepSeek Harness)
          ├── SillyTavern
          └── other loopback Web apps
```

## Quick start

### 1. Get the project

```bash
git clone https://github.com/hxaxd/remote-everything.git
cd remote-everything
```

### 2. Install a mobile client

Android can install the signed APK from the current [Release](https://github.com/hxaxd/remote-everything/releases). When there is no matching official distribution channel, iOS must be signed and installed on macOS with Xcode/XcodeGen under your own development identity, and HarmonyOS must be built and installed with DevEco Studio under your own debug signing; see the [client acquisition notes](skills/remote-everything-install/references/mobile-clients.md).

### 3. Let an Agent finish deployment

Tell the Agent in this repository:

```text
Deploy Remote Everything for me
```

Then choose same-network or remote access, scan the QR code, and—in public mode—verify the full device fingerprint. The node, dynamic ports, certificates, service managers, and runtime records are handled by the install Skill.

Everyday operations use natural language as well:

- `Add the XX app on this machine to Remote Everything`
- `Pair this mobile device`
- `Check the current status`
- `Upgrade to the latest version`
- `Uninstall and clean the runtime environment`

## Security model

- **LAN**: before opening a remote app, the client confirms the gateway with the server-certificate SHA-256 fingerprint from the QR code, and also checks certificate validity and the target host; the entry only allows the selected LAN or overlay interfaces.
- **Public**: pairing invitations are single-use and time-limited. Device certificates stay pending until the user verifies the full fingerprint and approves them; later requests use both mTLS and the device record.
- **Server side**: the control token exists only on the Gateway–Node path; public mode only reuses port 443.
- **Client side**: device credentials go into system secure storage; Web data is isolated in each platform's WebView; external links open in the system browser.
- **Supply chain**: release assets include SHA-256 digests; stable clients use a fixed signature or the platform's official distribution signing.

Do not open a public Issue for a security vulnerability; report privately via the [Security Policy](SECURITY.md).

## Good fit

- Check and operate the DSH (DeepSeek Harness) console on a home or office computer while commuting;
- Use local SillyTavern on a mobile device with an isolated login state;
- Manage computers on different OSes with one client without exposing each app's raw port.

## Contributing

```text
clients/   three mobile clients and shared contracts
nodes/     Windows / Linux / macOS nodes
server/    LAN entry and public gateway
internal/  shared Go core
apps/      adapted apps
skills/    executable operational workflows
```

- [Contributing Guide](CONTRIBUTING.md)
- [Security Policy](SECURITY.md)

## FAQ

<details>
<summary><strong>Do I need a public IP or domain?</strong></summary>

No. Use the LAN entry on the same network; remotely you can reuse an existing overlay, or use your own Linux public server.
</details>

<details>
<summary><strong>Does traffic pass through servers run by the project maintainers?</strong></summary>

No. Traffic only moves among your mobile devices, computers, LAN/overlay, and—if you have one—your own public server.
</details>

<details>
<summary><strong>Does it cost money?</strong></summary>

The project is free and open source under Apache-2.0.
</details>

## License

[Apache License 2.0](LICENSE)
