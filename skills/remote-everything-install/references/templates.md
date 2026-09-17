# 部署模板

`assets/` 中的模板使用 `{{NAME}}` 占位符。把组件初始化输出和目标系统观测值作为只含该模板精确字段的 JSON，通过标准输入调用 `scripts/render.py KIND --input - --output TARGET`；需要保存可复现输入时再把 `-` 换成文件路径。Windows 另传 `--launcher-output TARGET.vbs`。渲染器按 systemd 参数、XML、Windows 命令行、VBScript、TOML 或 Caddy token 的上下文编码，拒绝未知字段、错误类型、相对路径和控制字符。不得直接字符串替换模板。

- `systemd-user.service.tmpl`：Linux 节点侧 `node/lan/frpc`；安装到部署用户的 `~/.config/systemd/user/`，用 `systemctl --user daemon-reload` 和 `systemctl --user enable --now` 管理，不启用 lingering，仅在该用户登录期间可用。服务 ID 里那个 64 位十六进制值按组件给：节点自己的服务（`node`）用它自己的 `node_id`，隧道（`frpc`）用它所属网关的 `installation_id`（一条隧道一个网关），入口（`lan`）用入口自己的 `installation_id`。
- `systemd.service.tmpl`：Linux 服务器侧 `gateway/frps`；安装到 `/etc/systemd/system/`，服务 ID 包含 `installation_id`，进程树由 `KillMode=control-group` 回收。
- `caddy-systemd.service.tmpl`：无既有 443 入口时的 Linux Caddy；以非 root 部署账户运行，只授予绑定 443 的 capability，并把证书数据与自动配置放入 `.runtime`。
- `launchd.plist.tmpl`：macOS 节点侧；安装到部署用户的 `~/Library/LaunchAgents/`，label 里那个 64 位十六进制值与上面同规则（`node` 用 `node_id`，`frpc` 用它所属网关的 `installation_id`，`lan` 用入口自己的），仅在该用户登录期间可用。
- `scheduled-task.xml.tmpl` / `hidden-launcher.vbs.tmpl`：Windows 节点侧；渲染器用确定的 Windows 命令行规则生成每组件隐藏启动器，计划任务由用户登录触发并只经 wscript 调用该启动器。任务名的 ID 与上同规则。
- `frpc.toml.tmpl` / `frps.toml.tmpl`：固定 FRP v0.70.0、wire protocol v2、WSS `/~!frp`、32 条预建工作连接及相同服务端池上限、由 443 入口验证的独立隧道客户端证书、系统信任的公网服务端证书、文件 token 和明文 loopback FRPS 上游；**每台节点的隧道端口只发布在 loopback 上**（`proxyBindAddr` 显式写死，不靠 frp 版本默认值——那是网关拨这台节点控制面的地址，默认值变一次就等于把它摆到公网上）。TLS 只在 frpc 到 443 入口这一段终止一次：出机器的只有到云端 443 的那一段，网关拨 frps、frps 拨节点的隧道端口都在本机 loopback 上。**一台节点一份 frpc 配置**：节点映射目标取自节点状态——`node_host` 是节点监听的主机（同机时是 `127.0.0.1`，节点在别处时是它自己的地址），`node_port` 是它的端口，两者由 Agent 从该节点的 `listen_address` 读出；`node_tunnel_port` 取该节点 `node add` 输出里 `node_address` 的端口（也是这个网关拨它的地址）；`node_id` 既是代理名（`node-<node_id>`，frps 用它区分多台节点的隧道，同一 frps 下重名会冲突），也是这份材料的目录名。
- `Caddyfile.tmpl`：固定 Caddy v2.11.4；配对、设备和隧道按路径与证书 issuer 分类，覆盖设备指纹头，所有上游取自 `server.json`。
- `scripts/cloud/frps-healthcheck/`：public 云端 frps 兜底探活，仅 Linux 服务器侧安装。`frps-healthcheck.sh` 与 `remote-everything-frps-healthcheck.service` 同样是 `{{NAME}}` 占位符模板，但不走 `render.py`；由该目录 `install.sh --installation-id <ID> --frps-listen <init 输出的 frps_listen> --tunnel-listen <每台节点的 node_address，一台一次>` 渲染四处占位符（脚本实际路径、installation_id、frps 自己的地址、全部节点隧道地址）并安装启用 timer。**它看的就是它要重启的东西**：重启的是 frps，所以判据落在 frps 上——frps 自己的端口连不上，或所有隧道一起断（它们共用这一个 frps，一起断就是它的问题）才重启；只有部分隧道断说明是那几台节点自己不在线，只记一行日志。因此每台节点的 `node_address` 都要给出来，只给一台就等于把那台关机当成 frps 楔死。systemd 不展开 ExecStart 可执行名中的环境变量，因此路径只能在安装期渲染，不得改成 `$VAR` 形式。

渲染后运行对应检查：`systemd-analyze verify`、`plutil -lint`、计划任务 XML 注册后查询，以及 `scripts/validate_deployment.py` 对 FRP/Caddy 的契约和原生解析检查。无现有入口时用 `render.py caddy-systemd` 生成 Caddy 系统服务；把模板、渲染文件、管理器 ID 和检查结果写入运行记录。
