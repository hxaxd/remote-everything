<div align="center">

# Remote Everything · 远程万物

**坐在工位前，用手机打开你电脑上的应用。**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=for-the-badge)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hxaxd/remote-everything?style=for-the-badge)](https://github.com/hxaxd/remote-everything/releases)
[![Platform](https://img.shields.io/badge/%E8%A2%AB%E6%8E%A7%E7%AB%AF-Windows%20%C2%B7%20Linux%20%C2%B7%20macOS-success?style=for-the-badge)](#remote-everything--远程万物)

**中文** · [English](README_EN.md)

[这是什么](#这是什么) · [亮点](#亮点) · [快速开始](#快速开始) · [常见问题](#常见问题)

</div>

## 这是什么

你的好应用都长在电脑上：Kimi Code 的网页版、SillyTavern、自己写的小工具。人一走开，它们就跟你没关系了。

远程万物把它们原样送进你的手机——不改应用、不搬上云、不用记任何地址。电脑上跑一个小节点，手机上装一个通用 APK，中间走你自己的服务器或组网。就这样。

## 亮点

- 🚀 **30 秒配对**：手机扫个码就完事。没有账号体系，没有地址、端口、密码要填。
- 🔐 **你点头才进得来**：新手机必须你亲手核对指纹、点批准；邀请码单次使用、限时失效。链路全程加密，服务器是你自己的。
- 🖥️ **三平台被控端**：Windows / Linux / macOS 随你登录运行，退出时自动收走应用进程，不留一点残留。
- 🌐 **同网异地都通**：同网络直连；异地走你的云服务器（共用一个 443）；没有服务器也不慌——已有组网直接用，没有就推荐免费 Tailscale。
- ✨ **打开就是登录态**：深度适配 KimiWeb 和酒馆，点进去直接用；其他本地 Web 应用一句话接入。
- 🤖 **全程 Agent 驱动**：安装、接入、升级、卸载，你说人话，Agent 干活。

## 适合干什么

- 通勤路上，接着用家里电脑上的 Kimi Code 干活
- 躺在床上，挂酒馆继续你的角色卡
- 自己跑的各种内部小工具，出门在外手机随时看一眼

## 快速开始

```bash
git clone https://github.com/hxaxd/remote-everything.git
cd remote-everything
```

然后给 Agent 发一句话：

```text
帮我部署
```

接下来你只做三件事：回答它两个选择题（同网还是异地、有没有服务器）→ 用手机扫它递来的二维码 → 核对指纹点批准。结束。

日常也是一句话的事：

- `把本机的 XX 应用接进远程万物`
- `给新手机配对`
- `升级一下` / `看看现在什么状态` / `卸载干净`

## 安全吗

手机要持有你这台网关签发的证书才能连上，而证书只发给你亲手批准的设备——批准前你要在手机和 Agent 两边核对同一串指纹。配对邀请单次使用、限时失效。流量只在你自己的设备之间流动：要么局域网直连，要么经过你自己的云服务器或组网，没有第三方经手。

## 它是怎么工作的

一句话：节点在你电脑上用 loopback 代理你注册的应用，手机经局域网入口或基于 FRP 的公网 mTLS 网关访问；APK 不含任何凭据，内部令牌不离开服务器。细节都在 [`skills/`](skills/) 里。

## 常见问题

**需要公网 IP 或域名吗？**
不需要。同网直连什么都不用；异地有两条路：你有云服务器就走服务器，没有就用免费 Tailscale 组网。

**手机上要装几个 App？**
一个。所有实例、所有应用共用一个通用 APK。

**电脑关机了会怎样？**
手机目录里显示电脑离线，开机后自己恢复，不用重新配对。

**有 iOS 吗？**
目前只有 Android 客户端。

**收费吗？**
Apache-2.0 开源免费。服务器是你自己的，没有人收你订阅费。

## License

[Apache-2.0](LICENSE)
