# 节点 CLI

三个平台共用以下接口；路径均为绝对路径。

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

`init` 只创建节点身份（随机 `node_id`、`listen_address`、空注册表与日志目录），不产生任何网关绑定；`serve` 不接受端口参数。`node_id` 是这台机器全局唯一的身份（32 字节随机，换地址、修端口都不变），网关记录它作为路由标签——手机先选节点，网关按 `X-Remote-Everything-Node` 把请求送到这台机器；它不承载信任，能不能进来由网关按自己的设备记录判。所以 `node_id` 要交给网关（`node add --node-id`），网关才知道这台机器是谁。`--listen` 是节点监听的地址，也是网关拨号用的地址，缺省 `127.0.0.1`：网关与节点同机（含公网形态的隧道入口）用缺省值，网关在局域网内另一台机器时由 Agent 指定该机器的局域网地址。只接受具体的 IPv4 地址，不接受 `0.0.0.0`、主机名或 IPv6——网关需要的是一个能连的地址。

网关通过 `binding add` 绑定到节点：bootstrap 目录由网关侧生成（`node add` 每台节点一份），节点校验 manifest 与令牌格式，把控制令牌写入 `bindings/<installation_id>/` 子目录。那份令牌是网关为**这台节点**单独签的（网关侧存在 `nodes/<node_id>`），所以一台机器泄露手里的令牌碰不到同网关下的其他机器。一个绑定只含身份——安装 ID 与控制令牌——节点不接收也不保管任何证书或隧道材料；网关自己拥有的一切留在网关侧，节点不思考它。重复添加同一 `installation_id` 幂等；同一安装换了控制令牌时报错，不覆盖成另一个安装。一个节点可绑定多个网关（如 LAN 入口 + 公网网关），控制接口接受任一绑定的控制令牌。绑定的增删对运行中的 `serve` 立即生效，无需重启。两种形态的网关走同一条路：LAN 入口和公网网关都自己产出身份 bundle，由 Agent 送到节点执行 `binding add`，没有入口能自己写节点状态。`binding remove` 删除绑定及其令牌，`binding list` 列出现有绑定。

`init` 输出 `ok`、`state`、`node_id`、`listen_address`；`binding add` 另输出 `installation_id`。

网关把这台机器撤出去之后（网关侧 `node remove`），机器上剩下的那份绑定已经没人认了，操作者要在本机执行 `binding remove <installation_id>` 并停掉/删除这台机器上对应的隧道代理与材料——网关那边不再有任何东西指向它。反过来，机器上的 `node_id` 与 `listen_address` 都不变：重新加入同一个网关时是 `node add` 一次并 `binding add` 一次，节点侧不需要 `init`；但控制令牌会重新签发，所以导入的是那时给的新 bundle。控制令牌泄漏时走网关侧 `node token renew`，本机同样是 `binding remove` 之后 `binding add --bootstrap <新目录>`（顺序与停机窗口见 [server-cli](server-cli.md)）。

端口冲突时先停服务，执行 `ports repair` 原子重分配并保持 `node_id`（自动避开已注册应用的 `proxy_url` 端口），同步运行记录后重启；public 形态还要按新地址重渲染这台节点的 FRPC 配置并重启它（`node_tunnel_port` 不变，它是网关那一侧的端口）。节点换了网络地址时用 `ports repair --listen HOST`：它同样保持 `node_id`，只把监听地址搬到新主机上；之后各网关对该节点重新执行一次 `node add --node-address <新地址>` 更新记录并重启即可，`installation_id`、客户端凭据与设备授权都不变。

应用定义拒绝未知字段和尾随 JSON：
```json
{"id":"demo","name":"Demo","description":"","icon":"D","accent":"#2563eb","launch_fragment":"","proxy_url":"http://127.0.0.1:3000","command":"/absolute/app","arguments":[],"stop_command":"","stop_arguments":[],"workdir":"/absolute/workdir"}
```

`id` 以字母或数字开头、最长 64，仅小写字母、数字、点、下划线和连字符。`proxy_url` 必须是不含路径与查询的 `127.0.0.1` HTTP 地址，且不能指向节点自身；探活从该地址派生。命令、非空停止命令和非空工作目录必须为绝对路径，非空工作目录必须已存在；定义文件不超过 64KB。

适配器源码常规放在定义同目录的 `adapter.js`，`app set` 注册时自动读取并随定义登记（上限 64KB）；也可直接写在定义的 `adapter` 字段里。`app list` 输出不包含适配器源码，需要时用 `app adapter --state PATH ID` 单独打印，没有适配器的应用报错退出。

`launch_fragment` 为空或以 `#` 开头，用于应用首次打开时向自身前端传递片段参数。公网形态它只出现在经 mTLS 鉴权设备的应用目录中；局域网形态入口不鉴权客户端，目录对能到达入口端口的所有人可见，敏感片段依赖网段防火墙收敛。

代理链路只剥离 `X-Remote-Everything-Client-Fingerprint` 与 `X-Remote-Everything-Node` 两个保留头（名字都在 `internal/backplane/proxysecurity`，网关那一跳与节点这一跳用的是同一份列表）；控制令牌不走应用链路，它是网关调节点控制面时用的 `Authorization: Bearer`（见下），应用自身的 `Authorization` 与其余头部原样透传。

显示名称 1—80 个 Unicode 字符且不含首尾空白，描述最多 240，图标最多 4；三者拒绝控制字符。`accent` 必须是六位十六进制颜色。代理 URL 拒绝 fragment。

控制接口为状态中 `listen_address` 的 `POST /__local_remote_control`，使用 `Authorization: Bearer <control-token>`，请求为 `list`、`status`、`start` 或 `stop`。
