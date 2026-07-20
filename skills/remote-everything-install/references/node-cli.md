# 节点 CLI

三个平台共用以下接口；路径均为绝对路径。

```text
remote-everything-control init --state PATH [--control-token-file FILE | --bootstrap DIRECTORY]
remote-everything-control ports repair --state PATH
remote-everything-control serve --state PATH
remote-everything-control app list --state PATH
remote-everything-control app set --state PATH --file DEFINITION.json
remote-everything-control app remove --state PATH ID
```

LAN 用无 bootstrap 的 `init` 创建节点身份；同目录的 LAN 入口读取其控制令牌。public 必须使用网关生成的 `--bootstrap`：节点严格校验证书链、客户端私钥、令牌和 manifest，导入网关创建的 `installation_id` 与隧道材料。已有节点状态或控制令牌不匹配时失败，不覆盖成另一个安装实例。两种形态都会自动选择并持久化 loopback `listen_address`，创建空注册表与日志目录；`serve` 不接受端口参数。`init` 输出 `ok`、`state`、`installation_id`、`listen_address`、`control_token_file`；public bootstrap 另输出 `frps_token_file`、`tunnel_ca_certificate_file`、`tunnel_client_certificate_file`、`tunnel_client_key_file`。

端口冲突时先停服务，执行 `ports repair` 原子重分配并保持 `installation_id`（自动避开已注册应用的 `proxy_url` 端口），同步运行记录后重启；public 形态还需按新节点地址重渲染 FRPC 配置并重启 FRPC。

应用定义拒绝未知字段和尾随 JSON：

```json
{"id":"demo","name":"Demo","description":"","icon":"D","accent":"#2563eb","launch_fragment":"","proxy_url":"http://127.0.0.1:3000","command":"/absolute/app","arguments":[],"stop_command":"","stop_arguments":[],"workdir":"/absolute/workdir"}
```

`id` 以字母或数字开头、最长 64，仅小写字母、数字、点、下划线和连字符。`proxy_url` 必须是不含路径与查询的 `127.0.0.1` HTTP 地址，且不能指向节点自身；探活从该地址派生。命令、非空停止命令和非空工作目录必须为绝对路径，非空工作目录必须已存在；定义文件不超过 64KB。

`launch_fragment` 为空或以 `#` 开头，用于应用首次打开时向自身前端传递片段参数。公网形态它只出现在经 mTLS 鉴权设备的应用目录中；局域网形态入口不鉴权客户端，目录对能到达入口端口的所有人可见，敏感片段依赖网段防火墙收敛。

代理链路只剥离 `X-Remote-Everything-Client-Fingerprint` 与 `X-Remote-Everything-Control-Token` 两个保留头；应用自身的 `Authorization` 与其余头部原样透传。

显示名称 1—80 个 Unicode 字符且不含首尾空白，描述最多 240，图标最多 4；三者拒绝控制字符。`accent` 必须是六位十六进制颜色。代理 URL 拒绝 fragment。

控制接口为状态中 `listen_address` 的 `POST /__local_remote_control`，使用 `Authorization: Bearer <control-token>`，请求为 `list`、`status`、`start` 或 `stop`。
