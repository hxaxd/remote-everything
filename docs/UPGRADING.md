# 升级指南

各组件独立升级，互不要求同时版本。任何升级都先本地验证（见 `PLAN.md` 第 1 节测试基线），保持变更最小。

## Android 客户端

同包名同签名**覆盖安装**，不要卸载（卸载会丢失本机凭据，需要重新审批）。升级后实机走一遍：目录 → 启动/停止 → 进入 → 边缘菜单。升级本身不影响远端服务，无断线。

签名材料位于 `%LOCALAPPDATA%\AgentRemoteSign\`（`android-release.jks` + 同名 `.password` 文件，与运行时状态目录分离，卸载运行时不会触碰）。**务必离线备份**：签名密钥丢失 = 无法发布同签名更新 = 用户必须卸载重装并重新审批。

## Windows 控制服务

重跑 `windows/install.ps1 -BundleDir <bundle>`：脚本会先停任务、杀旧进程、重新构建并恢复任务，幂等可重跑。中断窗口约几秒（计划任务重启期间手机端显示电脑离线，自动恢复）。

## 云服务器

```powershell
scp -r .\server "root@<服务器>:/root/agent-remote-server"
ssh "root@<服务器>" "PUBLIC_HOST='<地址>' WINDOWS_USER='<用户>' /root/agent-remote-server/install_gateway.sh"
```

`install_gateway.sh` 幂等：已存在的密钥、令牌、证书一律保留，只更新程序与配置。随后跑服务端全链路测试（`PLAN.md` 第 1 节）。中断窗口为各服务 reload/restart 的秒级时间。

顺序约定：先 Windows 控制程序，再云端 status 服务，Caddy 配置最后 reload；enrollment 服务仅在自身变更时重启。

## 回滚

- Android：保留上一版 APK 直接覆盖装回。
- Windows/云端：重跑上一版代码对应的安装脚本。状态文件（注册请求、已批证书、应用注册表、令牌）任何版本升级都不触碰。
