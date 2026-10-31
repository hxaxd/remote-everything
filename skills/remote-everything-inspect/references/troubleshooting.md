# 连接排障与隧道恢复

先确认入口访问日志和时间范围，再结合客户端请求定位；“没有日志”只有在对应入口确实记录这类请求时才是证据。

## 按观测分类

| 观测 | 下一步 |
| --- | --- |
| 同设备访问多个无关站点也失败 | 检查设备网络、VPN 和 DNS |
| 目标请求未到入口 | 检查设备→入口的 DNS、TCP/TLS、代理及外部入站规则 |
| `/nodes` 正常，但没有 `/apps` 请求 | 检查客户端所选节点/路由及是否发起目录请求 |
| 目录返回 `computer_connected:false` | 从网关检查节点地址、控制令牌和对应 FRPC/隧道 |
| 请求返回 401/403 | 核对证书、设备状态、节点授权；应用页面 403 另检查自身 Host/Origin 白名单 |

## 隧道断开

按 `node list` 的 `address` 检查回环隧道端口，再看节点 FRPC 与网关 FRPS 日志。`i/o deadline reached`、`replaced by client`、`proxy already exists`、工作池告警是定位线索，不能仅凭其中一条判定某进程故障。工作池配置见 [templates.md](../../remote-everything-install/references/templates.md#frp-配置)，自动恢复判据见 [健康检查](../../remote-everything-install/references/frps-healthcheck.md)。

确认需要重启恢复后，按 update Skill 执行：

1. 停目标 FRPC 启动器，按 runtime 身份清理该组件残留，确认匹配进程为 0；Windows 停任务不等于代理已经退出。
2. 重启该网关 FRPS，再启动该条 FRPC。
3. 确认该组件匹配进程恰好一个，并验证实际节点目录和应用；其它网关代理应保留。

Windows 可用 `scripts/recover-frp-tunnel.ps1 -InstallationId <ID> -RuntimePath <runtime.json> -ComponentId <组件ID> -ServerAlias <SSH别名> -TunnelProbe <回环节点探活URL>`；此脚本会执行停止和重启，不属于只读巡检。

## TCP 通但 TLS 失败

对照 DNS 解析、同一 IP 上携带不同服务端名字的 TLS 握手，以及入口日志；TCP 建连不能证明域名的 TLS 通路正常。客户端启用 Fake-IP/TUN 或出站代理时，检查实际解析/分流规则，临时直连目标服务并重建连接复测；绕过代理不能修复上游按 SNI 的拦截。

外部端口是否可达必须从外网测试：本机 curl 成功不代表主机防火墙和云安全组允许入站。域名选择与更换流程见 [networking.md](../../remote-everything-install/references/networking.md)。

## 应用与凭据

- 改过 origin 后，核对客户端是否仍保存旧连接，并按 device Skill 重新配对。
- 页面可开而 API/实时链路失败，检查[适配器](../../remote-everything-app/references/patterns.md#适配器adapterjs)对 Host/Origin/Referer 的处理。
- 应用二进制被外部升级后仍是旧行为，按 [app Skill 更新流程](../../remote-everything-app/SKILL.md#更新) 停止并重新启动。
