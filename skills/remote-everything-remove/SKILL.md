---
name: remote-everything-remove
description: 停止并清理 Remote Everything。用于移除节点、局域网入口、公网网关、FRP、项目管理的反向代理或整个运行目录。
---

读取 [runtime.md](../remote-everything-install/references/runtime.md)，验证目标 `.runtime/runtime.json`。

1. 用节点本地控制接口停止全部已登记应用。
2. 节点按 `frpc/lan → node` 停止；服务器按 `gateway/frps → 项目管理的 reverse-proxy` 停止。
3. 仅删除运行记录中 `managed=true` 的对象；复用对象只撤销记录的精确插入片段并保留其余配置；外部远程组网始终保留。
4. 用 PID、启动时间、可执行文件和完整参数核对并结束残留进程。
5. 确认登记端口释放、系统引用消失后删除该 `.runtime`；用户同时要求删除源码时再处理项目目录。

返回停止的组件、移除的集成、删除的目录和未能匹配运行记录的残留。
