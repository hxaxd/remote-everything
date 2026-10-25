---
name: remote-everything-remove
description: 按指定范围移除 Remote Everything 的应用、节点绑定、单个组件、网关或整套部署，并保留其它绑定及复用对象。
---

先验证 [runtime.md](../remote-everything-install/references/runtime.md)，从用户意图、组件 owner 和复用关系确定范围；范围不明确时先澄清。

## 选择移除路径

| 范围 | 执行动作 | 保留对象 |
| --- | --- | --- |
| 单个应用 | 按 [app Skill](../remote-everything-app/SKILL.md#移除) 停止并注销 | 节点、网关及其它应用 |
| 撤销一条节点绑定 | 网关 `node remove` 后重启；节点 `binding remove`；停掉并删除该条 FRPC 的服务、配置和材料 | 节点身份、应用、其它网关绑定 |
| 只移除一个 FRPC 等组件 | 停止目标组件，删除其受管服务与专属产物，更新引用和记录 | 其它组件及共享状态；该隧道会不可达 |
| 移除一个网关 | 逐台撤销它的节点绑定，停网关侧组件，移除本站点/规则及该网关状态 | 被其它路复用的节点、应用和入口服务 |
| 移除节点本身 | 停止全部登记应用，注销该节点涉及的网关记录，再停节点并清理其专属状态 | 各网关及其余节点 |
| 整套独占部署 | 合并上述步骤，按依赖顺序移除全部目标受管对象 | `managed:false` 的外部服务与数据 |

节点增删、绑定命令与授权变化见 [server-cli.md](../remote-everything-install/references/server-cli.md#节点增删与令牌续换)；不因撤销一条网关路而停止整台节点上的应用。

## 停止、删除和核验

1. 按依赖方先停：节点侧 FRPC/受影响 LAN→node；服务器侧先停目标网关的[健康检查](../remote-everything-install/references/frps-healthcheck.md)，再停 gateway/LAN→FRPS→项目独占的 reverse-proxy。LAN 隧道组件见 [lan-tunnel.md](../remote-everything-install/references/lan-tunnel.md)。只执行所选范围涉及的步骤。
2. 按运行记录的 executable、完整参数、PID 和启动时间复核残留进程后结束目标进程树；Windows 停计划任务后的处理见 [templates.md](../remote-everything-install/references/templates.md#服务管理器)。
3. 仅删除目标拥有的 `managed:true` 对象；共享入口只撤销本站点的精确配置与规则，保留服务和其它站点。同步剩余节点的健康检查名单；最后一个节点移除时按其参考停用隧道检查。
4. 验证目标端口释放、管理器定义及引用已清除，更新 runtime。只有目录内不再保留其它组件、绑定或复用对象时才删除整个运行目录；否则只清理目标子目录。源码另按用户明确要求处理。

报告停止的组件、撤销的绑定、删除的产物、保留的共享对象及未能确认归属的残留。
