# 节点 CLI

三个平台共用以下接口；路径参数使用绝对路径。

```text
remote-everything-control init --state PATH [--listen HOST]
remote-everything-control binding add --state PATH --bootstrap DIRECTORY
remote-everything-control binding remove --state PATH INSTALLATION_ID
remote-everything-control binding list --state PATH
remote-everything-control ports repair --state PATH [--listen HOST]
remote-everything-control serve --state PATH
remote-everything-control app list --state PATH
remote-everything-control app adapter --state PATH ID
remote-everything-control app set --state PATH --file DEFINITION.json
remote-everything-control app remove --state PATH ID
```

## 初始化与绑定

`init` 创建稳定的 `node_id`、动态 `listen_address` 和空应用注册表，输出 `ok/state/node_id/listen_address`。`--listen` 是具体 IPv4 地址：同机网关或本机 FRPC 使用默认 `127.0.0.1`，远端直连网关使用节点的可达地址；不接受通配地址、主机名或 IPv6。`serve` 读取持久化地址，不接收端口参数。

网关生成的交付目录由 `binding add --bootstrap` 导入；节点只保存其中的安装 ID 与控制令牌，隧道材料交给独立 FRPC。目录契约见 [server-cli.md](server-cli.md#节点交付与隧道材料)。一个节点可有多个绑定，任一绑定的令牌均能访问控制接口。添加相同绑定幂等；同安装 ID 的令牌变更须先 remove 再 add。绑定增删即时生效，不需要重启节点。

## 地址与端口维护

先停节点，执行 `ports repair [--listen HOST]`，同步运行记录后重启。它保持 `node_id`，避开已登记应用的代理端口；随后按实际连接方式更新：

| 连接方式 | 配套操作 |
| --- | --- |
| LAN 网关直连节点 | 在每个直连网关用相同节点 ID 重新 `node add --node-address <新地址>`，保留名字及连接声明，再重启该网关 |
| public 或 LAN 隧道 | 重新渲染该节点 FRPC 的 `node_host/node_port` 并重启 FRPC；网关分配的隧道地址及 `node_tunnel_port` 不变 |

两种操作都不改变客户端凭据或设备授权。网关撤销节点、控制令牌续换的流程见 [server-cli.md](server-cli.md#节点增删与令牌续换)。

## 应用定义与控制

定义拒绝未知字段和尾随 JSON；示例：

```json
{"id":"demo","name":"Demo","description":"","icon":"D","accent":"#2563eb","launch_fragment":"","proxy_url":"http://127.0.0.1:3000","command":"/absolute/app","arguments":[],"stop_command":"","stop_arguments":[],"workdir":"/absolute/workdir"}
```

- `id` 是 1—63 字符的单个主机标签：小写字母、数字及内部连字符，首尾必须为字母或数字；规则来自 `internal/wire.AppIDPattern`。
- 显示名称 1—80 个 Unicode 字符，描述最多 240、图标最多 4，均拒绝控制字符及首尾空白；`accent` 为六位十六进制颜色。
- `proxy_url` 必须是无路径、查询或 fragment 的 `127.0.0.1` HTTP 地址，不能指向节点自身。探活地址从它派生。
- 启动命令、非空停止命令、非空工作目录须为绝对路径，工作目录须存在。定义及适配器各不超过 64KB。
- 停止辅助命令正常结束、执行失败或超时取消后，节点都会清理它启动的受管后代进程。
- `launch_fragment` 为空或以 `#` 开头，用于应用首次打开；两种网关的应用目录都受设备授权保护。

`app set` 会读取同目录 `adapter.js`，也支持定义内的 `adapter` 字段；`app list` 不输出源码，`app adapter ID` 单独读取。适配器行为与应用验收见 [patterns.md](../../remote-everything-app/references/patterns.md)。

控制接口是 `listen_address` 上的 `POST /__local_remote_control`，用 `Authorization: Bearer <control-token>` 调用 `list/status/start/stop`。代理到应用前，共享过滤器 `internal/proxysecurity.StripInternalHeaders` 剥离设备指纹、节点头及四个 Web 凭据头；网关控制令牌不进入应用请求，应用自身的 `Authorization` 保留。
