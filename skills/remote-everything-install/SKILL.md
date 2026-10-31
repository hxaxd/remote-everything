---
name: remote-everything-install
description: 安装或重建 Remote Everything。用于选择直连或隧道拓扑，取得发布资产，初始化节点和网关，配置服务与入口，并交付客户端配对。
---

1. 确认部署范围、目标机器/平台、已有节点和网关。已有运行物先验证 [runtime](references/runtime.md)，复用节点身份；需要重建的部分按 remove Skill 清理。
2. 按 [networking.md](references/networking.md) 选择拓扑和域名，并检查[应用信任边界](../remote-everything-app/SKILL.md#应用信任边界)。多节点或多网关按 [multi-computer.md](references/multi-computer.md) 组织归属。
3. 按 [releases.md](references/releases.md) 校验同一标签的二进制，按 [mobile-clients.md](references/mobile-clients.md) 取得所需客户端。
4. 按 [server-cli.md](references/server-cli.md) 初始化网关；在每台机器按 [node-cli.md](references/node-cli.md) 初始化或复用节点，再逐台登记、投递交付目录并导入绑定。使用实际初始化输出写运行记录。
5. 按 [templates.md](references/templates.md) 渲染、校验和安装服务。public 另读 [reverse-proxy.md](references/reverse-proxy.md)，LAN 隧道另读 [lan-tunnel.md](references/lan-tunnel.md)。启动节点、所需隧道与入口；已有入口增删节点后按 `restart_required` 重启。
6. public 有节点时安装并验证 [FRPS 健康检查](references/frps-healthcheck.md)。逐台确认网关能访问节点目录，不以 FRPS 端口开放代替隧道验收。
7. 有节点且用户可操作时，调用 [device Skill](../remote-everything-device/SKILL.md) 交付邀请并完成对应准入。空网关可先运行，不要求为初始化临时添加节点。
8. 验证本次部署的目录、控制和应用代理、未认证拒绝及节点授权范围；不要为验收吊销用户唯一凭据。更新 runtime 的组件、摘要、观测和验证，报告完成范围及需要用户执行的客户端动作。
