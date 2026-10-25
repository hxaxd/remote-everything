# 多节点与多网关

## 选择共享还是独立网关

| 需要 | 部署方式 |
| --- | --- |
| 同一套设备信任访问多台电脑 | 一个网关登记多台节点；用 `device grant` 为已有设备追加节点 |
| 独立的设备信任与审批 | 分别初始化网关，各有 installation ID、CA、运行记录和对外 origin |
| 一台电脑同时通过多条路访问 | 复用同一个节点和 node_id，为每个网关追加绑定；隧道按网关分别管理 |

## 向现有网关添加电脑

1. 在那台电脑初始化节点，取得 `node_id` 和 `listen_address`。
2. 网关执行 `node add`，使用独立的名字和交付目录。直连 LAN 显式给节点地址；隧道接入省略它，由网关分配地址。命令和输出字段见 [server-cli.md](server-cli.md)。
3. 将目录交给那台电脑导入绑定。需要隧道时，在该节点机器上渲染配置并启动 FRPC；字段见 [templates.md](templates.md#frp-配置)，无域名分支见 [lan-tunnel.md](lan-tunnel.md)。
4. 重启网关，逐台验证目录可达；按 [device Skill](../../remote-everything-device/SKILL.md) 发邀请或给已有设备追加权限。LAN 是否人工审批取决于 `--require-approval`。

移除其中一台按 [remove Skill](../../remote-everything-remove/SKILL.md) 的“撤销一条节点绑定”执行；public 同步更新健康检查的节点名单。节点自己的 ID 和其它网关绑定保留。

## 多个网关共享服务器

每个 public 网关使用独立域名/origin，以及自己的上游端口。`render.py caddy` 一次只生成一个网关的配置，默认部署是 1:1。共享 Caddy 时需手工合并完整配置并验证：网关主机、应用主机、8443 站点及全局 `on_demand_tls.ask` 都要覆盖对应网关，不能只追加一个反代块。模板未提供多网关的 ask 聚合器；无法完成按域名检查时，分别部署入口。

同一个节点被多个网关复用时，材料、进程和管理器名称按 installation ID 隔离，节点本身的唯一 owner 和复用记录见 [runtime.md](runtime.md)。客户端每条网关路分别配对和授权；具体客户端交互以其行为契约为准。
