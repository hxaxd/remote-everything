# SillyTavern接入要点

确定 ID：`sillytavern`。

1. **先收窄监听**：在 SillyTavern 的 `config.yaml` 设 `listen: 127.0.0.1`，端口避开节点首选端口 58627 与其他已注册应用；只经节点代理暴露，不直接监听局域网。
2. **无应用内鉴权**：未启用其内置 basicAuth 时，能到达入口的任何人都能使用——公网形态由 mTLS 设备鉴权兜底，LAN 形态依赖网段防火墙收敛。需要应用内鉴权时自行开启并在此记录。
3. **WebSocket 经代理透传**，无需特殊配置。
4. `workdir` 为 SillyTavern 检出目录；`stop_command` 留空，停止由节点回收整棵进程树。
5. **验证**：从真实移动客户端入口打开酒馆首页与一次对话，确认 WebSocket 正常；与已登记应用逐一复验共存（共享网关 origin、客户端 Web 数据按应用隔离，见 `remote-everything-app` skill）。
