# 公网 443 入口

从 `server.json` 读取真实上游地址。入口必须：

1. 以受系统信任的服务端证书提供独立 HTTPS 域名。
2. 仅让 `/__remote_everything_pair` 无客户端证书访问配对上游。
3. 让 `/__remote_everything_activate` 和其他设备路径验证设备 CA，把实际客户端叶证书 SHA-256 指纹覆盖写入 `X-Remote-Everything-Client-Fingerprint` 后转发状态上游。
4. 让精确 FRP WSS 路径只验证独立隧道 CA 并转发 FRPS loopback 上游。
5. 丢弃客户端提交的同名指纹头；所有项目上游保持 loopback。

先以能够读取 socket PID 的权限运行 `scripts/inspect_443.py`。脚本从 443 监听 PID 的 cgroup 精确解析 systemd unit 与 FragmentPath；非 systemd 进程返回真实 executable。端口已占用但 PID 不可见、系统命令失败或 unit 定义不明确时脚本以 `ok:false` 失败，不猜测 owner。然后检查该 owner 的证书验证、issuer 路由、WebSocket 和叶证书 SHA-256 指纹能力。满足契约时生成只包含本站点的最小片段，验证完整配置后原子重载，并记录真实插入点和恢复方法。

没有现有入口时，在 `.runtime/bin/` 安装固定版本 Caddy，使用项目模板渲染完整站点，并用 `render.py caddy-systemd` 生成非 root 独立服务。服务只获得绑定 443 的 capability，证书数据与自动配置目录都位于 `.runtime`。模板同时关闭 HTTP 重定向与 ACME HTTP-01，只使用 443 的 TLS-ALPN 完成证书签发，不新增 80 监听。设备路径与隧道路由必须使用不同 CA 匹配器，不得把两个 CA 混成同一可访问集合。

验收：无证书只能访问配对；pending 只能提交或轮询审批；人工批准前不能访问应用；approved 可访问；伪造指纹无效；吊销立即失败；FRPC 只能通过专用 WSS 路径连接；没有新增公网业务端口。
