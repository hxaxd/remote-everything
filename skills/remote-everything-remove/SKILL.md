---
name: remote-everything-remove
description: 停止并清理 Remote Everything。用于移除节点、局域网入口、公网网关、FRP、项目管理的反向代理或整个运行目录。
---

读取 [runtime.md](../remote-everything-install/references/runtime.md)，验证目标 `.runtime/runtime.json`。

1. 用节点本地控制接口停止全部已登记应用。
2. 节点按 `frpc/lan → node` 停止（每个节点的 frpc 各是一条组件，逐条停）；服务器先停用 frps 健康检查 timer（`systemctl disable --now remote-everything-frps-healthcheck.timer`），再按 `gateway/frps → 项目管理的 reverse-proxy` 停止。
3. 仅删除运行记录中 `managed=true` 的对象；复用对象只撤销记录的精确插入片段并保留其余配置；外部远程组网始终保留。删除整套公网部署时，健康检查产物在 `.runtime` 之外，需一并删除 `/etc/systemd/system/remote-everything-frps-healthcheck.{service,timer}` 与渲染安装的 `frps-healthcheck.sh`（默认 `/usr/local/bin/`）并 daemon-reload；仅重建 frps 时保留健康检查，按 install Skill 用相同参数重跑其 `install.sh`（幂等）。
4. 用 PID、启动时间、可执行文件和完整参数核对并结束残留进程。
5. 确认登记端口释放、系统引用消失后删除该 `.runtime`；用户同时要求删除源码时再处理项目目录。入口与节点不在同一台机器上时，两台机器各有自己的 `.runtime`，分别在各自机器上移除。

返回停止的组件、移除的集成、删除的目录和未能匹配运行记录的残留。
