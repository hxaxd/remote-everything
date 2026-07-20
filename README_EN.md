<div align="center">

# Remote Everything

**Open apps running on your computers — from your phone, right where you sit.**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=for-the-badge)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hxaxd/remote-everything?style=for-the-badge)](https://github.com/hxaxd/remote-everything/releases)
[![Platform](https://img.shields.io/badge/nodes-Windows%20%C2%B7%20Linux%20%C2%B7%20macOS-success?style=for-the-badge)](#remote-everything)

[中文](README.md) · **English**

[What is this](#what-is-this) · [Highlights](#highlights) · [Quick start](#quick-start) · [FAQ](#faq)

</div>

## What is this

Your favorite apps live on your computers: the Kimi Code web UI, SillyTavern, little tools you built yourself. The moment you step away, they're out of reach.

Remote Everything brings them to your phone as they are — no app changes, no moving to the cloud, no addresses to remember. A small node runs on your computer, one universal APK on your phone, and the traffic goes through your own server or overlay network. That's it.

## Highlights

- 🚀 **Pair in 30 seconds**: scan a QR code and you're done. No accounts, no addresses, ports or passwords to type.
- 🔐 **Nothing gets in without your nod**: a new phone only connects after you personally verify its fingerprint and approve it; invites are single-use and time-limited. Encrypted end to end, on your own server.
- 🖥️ **Three node platforms**: Windows / Linux / macOS, running in your login session and reaping the whole app process tree on exit — nothing left behind.
- 🌐 **LAN and WAN**: direct on the same network; remote through your own cloud server (sharing a single 443); no server? Reuse your existing overlay network, or get pointed to the free Tailscale.
- ✨ **Apps open signed in**: deeply adapted for KimiWeb and SillyTavern; any other local web app is one sentence away.
- 🤖 **Fully agent-driven**: install, onboard apps, upgrade, uninstall — you say it in plain words, the agent does the work.

## What it's good for

- On the commute, pick up right where Kimi Code left off at home
- In bed, keep your SillyTavern roleplay going
- All the little internal tools you self-host, one tap away wherever you are

## Quick start

```bash
git clone https://github.com/hxaxd/remote-everything.git
cd remote-everything
```

Then tell your agent (e.g. Kimi Code CLI):

```text
Deploy it for me
```

You only do three things: answer its two questions (same network or remote, got a server or not) → scan the QR code it hands you → verify the fingerprint and approve. Done.

Everyday use is one sentence too:

- `Add the XX app on this machine`
- `Pair a new phone`
- `Upgrade` / `Show me the current status` / `Uninstall cleanly`

## Is it safe

Your phone can only connect with a certificate issued by your gateway, and certificates go only to devices you approved yourself — after checking the same fingerprint on both the phone and the agent side. Pairing invites are single-use and time-limited. Traffic flows only between your own devices: direct on the LAN, or through your own cloud server or overlay network. No third party ever touches it.

## How it works

In one sentence: a node proxies the apps you register over loopback on your computer, and your phone reaches them through a LAN entrance or an FRP-based public mTLS gateway; the APK carries no credentials and internal tokens never leave the server. Details live in [`skills/`](skills/).

## FAQ

**Do I need a public IP or a domain?**
No. On the same network you need nothing; for remote access there are two paths — your own cloud server with port 443, or the free Tailscale overlay network.

**How many apps do I install on my phone?**
One. Every instance and every app shares the same universal APK.

**What happens when the computer is off?**
The catalog shows it offline, and it comes back on its own once powered on — no re-pairing needed.

**iOS?**
Android only, for now.

**What does it cost?**
Free and open source under Apache-2.0. The server is yours — nobody charges you a subscription.

## License

[Apache-2.0](LICENSE)
