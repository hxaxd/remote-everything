---
name: remote-everything-install
description: 安装或重建 Remote Everything。用于对齐节点、Android、局域网、已有远程组网或 Linux 公网服务器拓扑，下载发布资产，建立运行记录与会话服务，接入 443，并生成手机扫码所需的初始化载荷。
---

读取 [releases.md](references/releases.md)、[runtime.md](references/runtime.md)、[node-cli.md](references/node-cli.md)、[server-cli.md](references/server-cli.md) 和 [templates.md](references/templates.md)。远程访问再读取 [networking.md](references/networking.md)；公网形态同时读取 [reverse-proxy.md](references/reverse-proxy.md)。

1. 确认节点平台与架构、Android 设备、是否同网、现有远程组网、Linux 公网服务器、域名、SSH 和 443 所有者。
2. 同网或已有远程组网选择 LAN；有 Linux 公网服务器选择 public。没有服务器、没有现成组网又需异地访问时，向用户说明需要先选择并建立手机与节点可达的远程组网，等待用户决定；项目不推荐或安装组网产品。
3. 从同一 GitHub Release 下载通用 APK 和对应二进制，核验 `SHA256SUMS`，放入 `.runtime/bin/`。
4. LAN 先初始化节点再初始化入口。public 先用网关 `init --node-bootstrap` 生成唯一身份和受保护的节点 bundle，经加密管理通道送到节点后执行节点 `init --bootstrap`；核对两端 `installation_id` 相同，再销毁传输副本。
5. 从初始化结果读取实际地址，用 `scripts/runtime.py` 创建 `runtime.json`，渲染服务并启动。节点侧 `node/lan/frpc` 使用部署用户的登录会话服务；Linux 服务器侧 `gateway/frps/reverse-proxy` 使用系统服务。LAN 初始化直接生成二维码；public 接通 FRP 和 443 后执行 `device invite` 生成二维码。
6. 让用户只安装通用 APK 并扫描二维码或粘贴 setup URI；不得要求用户填写模式、端口、地址、指纹、密码或令牌。
7. 验证目录、控制与应用代理；public 另验证未认证拒绝、激活成功及 approved 设备可用，不吊销用户刚完成配对的唯一设备。手机提交成功后删除 Agent 创建的二维码、setup URI 和 bootstrap 传输副本。
8. 更新运行记录的观测状态与验证结果，输出 APK 来源、已完成的手机初始化、运行记录位置和验证摘要。
