<div align="center">

# Remote Everything · 远程万物

**让电脑上的本地 Web 应用，安全地出现在你的移动设备上。**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue?style=for-the-badge)](LICENSE)
[![Release](https://img.shields.io/github/v/release/hxaxd/remote-everything?style=for-the-badge)](https://github.com/hxaxd/remote-everything/releases)
[![Clients](https://img.shields.io/badge/客户端-Android%20·%20iOS%20·%20HarmonyOS-7c3aed?style=for-the-badge)](#支持范围)
[![Nodes](https://img.shields.io/badge/节点-Windows%20·%20Linux%20·%20macOS-059669?style=for-the-badge)](#支持范围)

**中文** · [English](README_EN.md)

[项目介绍](#项目介绍) · [核心能力](#核心能力) · [快速开始](#快速开始) · [安全模型](#安全模型) · [参与项目](#参与项目)

</div>

## 项目介绍

DSH（DeepSeek Harness）、SillyTavern（酒馆）和你自己写的小工具都运行在电脑上，但你不必一直坐在电脑前。

Remote Everything 在电脑上运行一个轻量节点，把明确登记的本地 Web 应用送到 Android、iOS 或 HarmonyOS 客户端。它不改造原应用、不把数据搬到第三方云端，也不要求维护一套账号系统：同网直接连接，异地则经过你自己的服务器或已有组网。

> 一个移动客户端，连接多台电脑；一个电脑实例，管理多个本地应用。

## 核心能力

- 🚀 **扫码即连**：安装客户端、扫描二维码、核对指纹，不手填地址、端口、密码或令牌。
- 📱 **三端原生客户端**：Android、iOS、HarmonyOS 使用相同协议和产品结构，并保留各平台原生安全与 Web 容器能力。
- 🖥️ **三平台电脑节点**：Windows、Linux、macOS 均在用户登录会话中运行，并在退出时回收受管应用进程树。
- 🔐 **设备级信任**：公网设备必须经过单次邀请、证书申请、完整指纹人工确认和 mTLS 激活。
- 🌐 **同网与异地**：LAN 或已有组网直接访问；公网模式复用服务器 443，由 Caddy 与 FRP 提供受控入口。
- 🧭 **多电脑切换**：每台电脑是独立 ID，客户端用多个 Profile 管理和切换，互不影响。
- 🧩 **应用即接即用**：已适配 DSH（DeepSeek Harness）与 SillyTavern（酒馆），其他本地 Web 应用也可按统一定义接入。
- 🤖 **Agent 驱动运维**：安装、接入应用、配对设备、巡检、升级和卸载都有可执行 Skill，不依赖手写部署笔记。

## 支持范围

| 类别 | 支持内容 |
|---|---|
| 移动客户端 | Android · iOS · HarmonyOS |
| 电脑节点 | Windows · Linux · macOS |
| 访问形态 | LAN / 远程组网 · Linux 公网网关 |
| 已适配应用 | DSH（DeepSeek Harness）· SillyTavern（酒馆） |
| 多电脑 | 每台电脑独立实例，客户端多 Profile 切换 |

## 工作原理

```text
Android / iOS / HarmonyOS
          │
          │ HTTPS（LAN 证书固定 / public mTLS）
          ▼
   LAN 入口或公网 Gateway
          │
          │ 内部控制令牌 + 受限反向代理
          ▼
 Windows / Linux / macOS Node
          │
          ├── DSH（DeepSeek Harness）
          ├── SillyTavern（酒馆）
          └── 其他 loopback Web 应用
```

## 快速开始

### 1. 取得项目

```bash
git clone https://github.com/hxaxd/remote-everything.git
cd remote-everything
```

### 2. 安装移动客户端

Android 可安装当前 [Release](https://github.com/hxaxd/remote-everything/releases) 中的已签名 APK。项目没有对应官方分发入口时，iOS 需要在 macOS 上用 Xcode/XcodeGen 以自己的开发身份签名安装，HarmonyOS 需要用 DevEco Studio 和自己的调试签名构建安装；详见[客户端取得说明](skills/remote-everything-install/references/mobile-clients.md)。

### 3. 让 Agent 完成部署

对仓库中的 Agent 说：

```text
帮我部署 Remote Everything
```

接下来只需要选择同网或异地访问、扫描二维码，并在公网模式下核对完整设备指纹。节点、动态端口、证书、服务管理器和运行记录都由安装 Skill 处理。

日常操作同样使用自然语言：

- `把本机的 XX 应用接进 Remote Everything`
- `给这台移动设备配对`
- `检查当前状态`
- `升级到最新版本`
- `卸载并清理运行环境`

## 安全模型

- **LAN**：客户端在打开远程应用前使用二维码中的服务端证书 SHA-256 指纹确认网关身份，并同时检查证书有效期与目标主机；入口仅允许指定局域网或组网接口访问。
- **公网**：配对邀请单次使用且限时有效。设备证书先处于 pending，用户核对完整指纹并批准后才会激活；后续请求使用 mTLS 和设备记录双重鉴权。
- **服务端**：控制令牌只存在于 Gateway 与 Node 链路，不进入移动客户端或发布包；公网只新增既有 443 流量。
- **客户端**：设备凭据存入系统安全存储；Web 数据按各平台可验证的最强语义隔离，外部链接交给系统浏览器。
- **供应链**：发布资产提供 SHA-256；正式客户端使用固定签名或平台官方分发签名，本地发行门禁与可选 CI 都会拒绝把部署凭据打进客户端。

安全漏洞请不要创建公开议题，按 [安全策略](SECURITY.md) 私密报告。

## 适合的场景

- 通勤途中随时查看和操作家里或工位电脑上的 DSH（DeepSeek Harness）控制台；
- 在移动设备上使用本机 SillyTavern（酒馆），同时保留独立登录态；
- 用一个客户端管理多台不同系统的电脑，而不暴露每个应用的原始端口。

## 参与项目

```text
clients/   三端移动客户端与共享协议
nodes/     Windows / Linux / macOS 节点
server/    LAN 入口与 public 网关
internal/  Go 共享核心
apps/      已适配应用
skills/    可执行运维流程
```

- [贡献指南](CONTRIBUTING.md)
- [支持说明](SUPPORT.md)
- [行为准则](CODE_OF_CONDUCT.md)
- [安全策略](SECURITY.md)

## 常见问题

<details>
<summary><strong>需要公网 IP 或域名吗？</strong></summary>

不需要。同网使用 LAN 入口；异地可以复用已有组网，也可以使用自己的 Linux 公网服务器。
</details>

<details>
<summary><strong>数据会经过项目维护者的服务器吗？</strong></summary>

不会。流量只在你的移动设备、电脑、局域网/组网和可能存在的你自己的公网服务器之间传递。
</details>

<details>
<summary><strong>收费吗？</strong></summary>

项目按 Apache-2.0 开源免费。
</details>

## License

[Apache License 2.0](LICENSE)
