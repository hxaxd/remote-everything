---
name: remote-everything-install
description: 安装或重建 Remote Everything。用于对齐节点、移动客户端、局域网、已有远程组网或 Linux 公网服务器拓扑，下载发布资产，建立运行记录与会话服务，接入 443，并生成移动设备扫码所需的初始化载荷。
---

读取 [releases.md](references/releases.md)、[mobile-clients.md](references/mobile-clients.md)、[runtime.md](references/runtime.md)、[node-cli.md](references/node-cli.md)、[server-cli.md](references/server-cli.md) 和 [templates.md](references/templates.md)。远程访问再读取 [networking.md](references/networking.md)；公网形态同时读取 [reverse-proxy.md](references/reverse-proxy.md)。已有部署再加一台电脑时，读取 [multi-computer.md](references/multi-computer.md)。

1. 确认节点平台与架构、移动设备平台（Android / iOS / HarmonyOS）、是否同网、现有远程组网、Linux 公网服务器、域名、SSH 和 443 所有者。
2. 同网或已有远程组网选择 LAN；有 Linux 公网服务器选择 public。需异地访问但既没有服务器也没有现成组网时，推荐免费虚拟组网 Tailscale 并指导用户建立，移动设备与节点互通后按 LAN 部署。
3. 从同一 GitHub Release 下载对应节点与服务端二进制并核验 `SHA256SUMS`，放入 `.runtime/bin/`；按 `mobile-clients.md` 取得同版本客户端。当前没有官方分发渠道时，Android 交付已签名 APK，iOS 与 HarmonyOS 分别由用户在 Xcode 与 DevEco Studio 中完成本地签名构建；不得代签，也不把客户端安装包写入节点运行目录。
4. 两种形态都是「网关自己生成身份 → bundle 送到节点 → 节点 `binding add --bootstrap` 导入」，没有入口能自己写节点状态。LAN：先初始化节点（入口与节点不同机时用 `init --listen <节点所在机器的局域网地址>`），再初始化入口（`init --state <入口自己的状态目录> --node-address <节点地址:端口> --node-bootstrap <bundle 目录>`），最后把 bundle 目录送到节点执行 `binding add`。public：先创建或选定网关服务账户并以之执行网关 `init --node-bootstrap`，生成唯一身份和受保护的节点 bundle，经加密管理通道送到节点后先执行节点 `init --state` 再执行 `binding add --bootstrap`。两种形态都要核对两端 `installation_id` 相同，再销毁传输副本。
5. 从初始化结果读取实际地址，用 `scripts/runtime.py` 创建 `runtime.json`，渲染服务并启动。节点侧 `node/lan/frpc` 使用部署用户的登录会话服务；Linux 服务器侧 `gateway/frps/reverse-proxy` 使用系统服务。LAN 初始化直接生成二维码；public 接通 FRP 和 443 后，从网关 systemd unit 的 `User` 读取服务账户，后续所有网关 CLI 均以该账户执行，待用户可立即操作时再执行 `device invite`。public 还必须安装 frps 健康检查定时器：在云端仓库目录执行 `scripts/cloud/frps-healthcheck/install.sh --installation-id <init 输出的 ID> --node-tunnel-listen <init 输出的 node_tunnel_listen>`，安装器渲染脚本与单元并启用 timer；不得手工拷贝该目录下的模板文件，部署后不得遗留占位符。`--node-bootstrap` 目录是交给节点机器的唯一交付物：在节点上执行 `binding add --bootstrap <该目录>` 导入身份，把其中的 `frpc/` 子目录放到节点机器的 `.runtime/state/frpc/<installation_id>/`（隧道代理自己的状态目录，与节点状态目录分开），再用 `scripts/render.py frpc` 渲染 frpc 配置——`node_host` 取节点 `listen_address` 的主机、`node_port` 取它的端口，材料路径取刚才放好的那三个文件。隧道客户端续期走 `gateway tunnel renew --state PATH --node-bootstrap <同一个目录>`，之后重投 `frpc/`、重启隧道代理即可，节点不需要重启。多网关时每条隧道各有自己的 frpc 进程、配置与材料目录，`runtime.json` 里也各是一条组件记录。
6. 向用户交付二维码或 setup URI 并说明准确失效时间；让用户安装其平台的通用客户端后提交设备申请，不得要求用户填写模式、端口、地址、指纹、密码或令牌。public 从 `device list` 读取申请的设备名与完整指纹，获得用户明确确认后执行 `device approve <指纹>`，客户端自动继续激活。
7. 验证目录、控制与应用代理；public 另验证未认证拒绝、人工批准前不可用、激活成功及 approved 设备可用，不吊销用户刚完成配对的唯一设备；同时确认 frps 健康检查 timer `enabled/active`，手动 `systemctl start remote-everything-frps-healthcheck.service` 一次并核对退出码与健康日志无 FAIL。客户端提交成功后删除 Agent 创建的二维码、setup URI 和 bootstrap 传输副本。
8. 更新运行记录的观测状态与验证结果，输出客户端来源、已完成的移动设备初始化、运行记录位置和验证摘要。
