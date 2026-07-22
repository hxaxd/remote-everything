# 部署模板

`assets/` 中的模板使用 `{{NAME}}` 占位符。把组件初始化输出和目标系统观测值作为只含该模板精确字段的 JSON，通过标准输入调用 `scripts/render.py KIND --input - --output TARGET`；需要保存可复现输入时再把 `-` 换成文件路径。Windows 另传 `--launcher-output TARGET.vbs`。渲染器按 systemd 参数、XML、Windows 命令行、VBScript、TOML 或 Caddy token 的上下文编码，拒绝未知字段、错误类型、相对路径和控制字符。不得直接字符串替换模板。

- `systemd-user.service.tmpl`：Linux 节点侧 `node/lan/frpc`；安装到部署用户的 `~/.config/systemd/user/`，用 `systemctl --user daemon-reload` 和 `systemctl --user enable --now` 管理，不启用 lingering，仅在该用户登录期间可用。
- `systemd.service.tmpl`：Linux 服务器侧 `gateway/frps`；安装到 `/etc/systemd/system/`，服务 ID 包含 `installation_id`，进程树由 `KillMode=control-group` 回收。
- `caddy-systemd.service.tmpl`：无既有 443 入口时的 Linux Caddy；以非 root 部署账户运行，只授予绑定 443 的 capability，并把证书数据与自动配置放入 `.runtime`。
- `launchd.plist.tmpl`：macOS 节点侧；安装到部署用户的 `~/Library/LaunchAgents/`，label 包含 `installation_id`，仅在该用户登录期间可用。
- `scheduled-task.xml.tmpl` / `hidden-launcher.vbs.tmpl`：Windows 节点侧；渲染器用确定的 Windows 命令行规则生成每组件隐藏启动器，计划任务由用户登录触发并只经 wscript 调用该启动器。
- `frpc.toml.tmpl` / `frps.toml.tmpl`：固定 FRP v0.70.0、wire protocol v2、WSS `/~!frp`、16 条预建工作连接及相同服务端池上限、由 443 入口验证的独立隧道客户端证书、系统信任的公网服务端证书、文件 token 和明文 loopback FRPS 上游。TLS 只在 frpc 到 443 入口这一段终止一次；节点映射端口取自状态。
- `Caddyfile.tmpl`：固定 Caddy v2.11.4；配对、设备和隧道按路径与证书 issuer 分类，覆盖设备指纹头，所有上游取自 `server.json`。

渲染后运行对应检查：`systemd-analyze verify`、`plutil -lint`、计划任务 XML 注册后查询，以及 `scripts/validate_deployment.py` 对 FRP/Caddy 的契约和原生解析检查。无现有入口时用 `render.py caddy-systemd` 生成 Caddy 系统服务；把模板、渲染文件、管理器 ID 和检查结果写入运行记录。
