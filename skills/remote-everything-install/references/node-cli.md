# 节点 CLI

三个平台共用以下接口；路径均为绝对路径。

```text
remote-everything-control init --state PATH
remote-everything-control binding add --state PATH --bootstrap DIRECTORY
remote-everything-control binding remove --state PATH INSTALLATION_ID
remote-everything-control binding list --state PATH
remote-everything-control ports repair --state PATH
remote-everything-control serve --state PATH
remote-everything-control app list --state PATH
remote-everything-control app adapter --state PATH ID
remote-everything-control app set --state PATH --file DEFINITION.json
remote-everything-control app remove --state PATH ID
```

`init` 只创建节点身份（随机 `node_id`、loopback `listen_address`、空注册表与日志目录），不产生任何网关绑定；`serve` 不接受端口参数。

网关通过 `binding add` 绑定到节点：bootstrap 目录由网关侧生成，节点校验 manifest 与令牌格式，把控制令牌写入 `bindings/<installation_id>/` 子目录。一个绑定只含身份——安装 ID 与控制令牌——节点不接收也不保管任何证书或隧道材料；网关自己拥有的一切留在网关侧，节点不思考它。重复添加同一 `installation_id` 幂等；同一安装换了控制令牌时报错，不覆盖成另一个安装。一个节点可绑定多个网关（如 LAN 入口 + 公网网关），控制接口接受任一绑定的控制令牌。绑定的增删对运行中的 `serve` 立即生效，无需重启。LAN 入口在自身 `init` 时自动建立绑定，无需手动 `binding add`。`binding remove` 删除绑定及其令牌，`binding list` 列出现有绑定。

`init` 输出 `ok`、`state`、`node_id`、`listen_address`；`binding add` 另输出 `installation_id`。

端口冲突时先停服务，执行 `ports repair` 原子重分配并保持 `node_id`（自动避开已注册应用的 `proxy_url` 端口），同步运行记录后重启；public 形态还需按新节点地址重渲染 FRPC 配置并重启 FRPC。

应用定义拒绝未知字段和尾随 JSON：
```json
{"id":"demo","name":"Demo","description":"","icon":"D","accent":"#2563eb","launch_fragment":"","proxy_url":"http://127.0.0.1:3000","command":"/absolute/app","arguments":[],"stop_command":"","stop_arguments":[],"workdir":"/absolute/workdir"}
```

`id` 以字母或数字开头、最长 64，仅小写字母、数字、点、下划线和连字符。`proxy_url` 必须是不含路径与查询的 `127.0.0.1` HTTP 地址，且不能指向节点自身；探活从该地址派生。命令、非空停止命令和非空工作目录必须为绝对路径，非空工作目录必须已存在；定义文件不超过 64KB。

适配器源码常规放在定义同目录的 `adapter.js`，`app set` 注册时自动读取并随定义登记（上限 64KB）；也可直接写在定义的 `adapter` 字段里。`app list` 输出不包含适配器源码，需要时用 `app adapter --state PATH ID` 单独打印，没有适配器的应用报错退出。

`launch_fragment` 为空或以 `#` 开头，用于应用首次打开时向自身前端传递片段参数。公网形态它只出现在经 mTLS 鉴权设备的应用目录中；局域网形态入口不鉴权客户端，目录对能到达入口端口的所有人可见，敏感片段依赖网段防火墙收敛。

代理链路只剥离 `X-Remote-Everything-Client-Fingerprint` 与 `X-Remote-Everything-Control-Token` 两个保留头；应用自身的 `Authorization` 与其余头部原样透传。

显示名称 1—80 个 Unicode 字符且不含首尾空白，描述最多 240，图标最多 4；三者拒绝控制字符。`accent` 必须是六位十六进制颜色。代理 URL 拒绝 fragment。

控制接口为状态中 `listen_address` 的 `POST /__local_remote_control`，使用 `Authorization: Bearer <control-token>`，请求为 `list`、`status`、`start` 或 `stop`。
