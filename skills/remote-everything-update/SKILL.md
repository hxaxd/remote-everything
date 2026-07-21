---
name: remote-everything-update
description: 升级已部署的 Remote Everything。用于从当前 runtime 识别拓扑，校验同一 Release 的新产物，按依赖顺序原子替换组件，引导三端移动客户端更新，并验证状态、凭据和动态端口保持一致。
---

读取 [releases.md](../remote-everything-install/references/releases.md)、[runtime.md](../remote-everything-install/references/runtime.md)、[node-cli.md](../remote-everything-install/references/node-cli.md) 和 [server-cli.md](../remote-everything-install/references/server-cli.md)。公网部署再读取 [templates.md](../remote-everything-install/references/templates.md) 与 [reverse-proxy.md](../remote-everything-install/references/reverse-proxy.md)。

1. 严格验证两端 `runtime.json`，记录当前 release、installation ID、状态文件、动态端口、二进制摘要、服务 owner、已登记应用和移动设备授权；不从进程名或固定端口猜测部署。
2. 读取目标 Release 的版本说明与 `SHA256SUMS`。状态 schema 或命令契约发生破坏性变化时，按 remove Skill 清理后调用 install Skill 重建；不运行迁移或兼容分支。
3. 把同一 Release 的目标平台二进制下载到运行目录外的临时缓存；Android 更新时同时取得正式 APK。核验摘要与目标平台可执行格式，并执行独立的 FRP/Caddy/服务模板验证；失败则不停止当前服务。iOS 与 HarmonyOS 只核对对应商店版本和项目发布标签，不下载或代签客户端包。
4. LAN 按 `入口 → node` 停止并按反序启动；public 节点按 `frpc → node` 停止、服务器按 `gateway → frps` 停止，再按依赖反序启动。每个二进制用同目录临时文件原子替换，保留旧文件只到该组件验证完成，失败立即恢复。Windows 节点侧组件经 wscript 隐藏启动后脱离计划任务实例，`schtasks /End` 不能结束其进程；替换 node/frpc 二进制前先 `taskkill /T /F` 结束进程树。
5. 不重新生成 installation ID、控制令牌、CA、设备证书、指纹或端口。只有运行证书剩余不超过 30 天时才调用 device Skill 的移动设备证书续期，或按 server CLI 执行同 CA 下的隧道客户端证书续期。
6. 逐层验证状态、目录、启停、应用代理；public 另验证 WSS、未认证拒绝和 approved 可用，仅在已有对应测试凭据时复验 revoked 拒绝，不为验收吊销真实设备。全部通过后更新 runtime 的 release、摘要、观测和验证字段并删除临时旧文件。
7. Android 在 `versionCode` 更高且签名指纹一致时交付正式 APK 或发布链接；iOS 引导到 TestFlight / App Store；HarmonyOS 引导到 AppGallery。客户端更新后不得要求重新填写连接，并验证原 Profile、LAN 指纹或公网设备凭据仍可用。

返回旧/新版本、替换组件、保持不变的身份与端口、验证结果，以及对应移动平台需要用户执行的更新动作。
