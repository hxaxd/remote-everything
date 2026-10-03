# iOS 客户端签名续期

iOS 客户端以 Apple 开发者账号签名装到真机；免费账号（Personal Team）描述文件 7 天过期，App 到期即无法启动。**免费账号上架 App Store / TestFlight 被拒（要求完成注册）是常态**，本仓库的 iOS 客户端只按真机调试形态维护。

## 路径选择

- **稳定常驻**：付费 Developer Program（¥688/年）→ 开发描述文件 1 年有效，签名流程不变，一年管一次。
- **零成本自动**：免费账号 + 定时重签 → 每 7 天循环自动续，适合开发期与单设备自用。
- **不装 Xcode 的旁观者**：TestFlight（90 天/版，免费账号上传通常走不通）或 AltStore / SideStore 自签（依赖第三方持续存活，稳定性不如定时重签）。
- **不推荐**：企业证书分发与第三方“超级签名”（违反条款、随时失效）；TrollStore 依赖 iOS 漏洞，新版不可用。

## 定时重签

**手动（应急）**：连 USB，`xcodebuild` 以 `-allowProvisioningUpdates` 自动管理签名构建，`xcrun devicectl device install app --device <UDID> <App>` 安装。构建命令、UDID 与本机事实见 `AGENTS.local.md`。

**自动（launchd，形态即“每日循环”）**：脚本每天由 LaunchAgent 触发一次，重签 → 编译 → `devicectl` 无线安装。三个要点：

- **目的地用 `generic/platform=iOS`**：编译签名不依赖手机在线；只有安装需要设备可达。
- **无线可达即同一 WiFi + 已配对**：锁屏不影响安装，仅影响“启动 App”这步（降级为忽略）；手机深睡时首次连接会被重置，探测（ping/dns-sd）本身常能唤醒，因此脚本按分钟级间隔重试，等待窗口设 45 分钟、次日再来，7 天窗口 = 最多 7 次机会。
- **Mac 侧容错**：launchd 在 `StartCalendarInterval` 错过时（睡眠）下次唤醒补跑；关机跨过则等次日。有确定的开机作息再考虑 `pmset` 定时唤醒，非必需。

**失败自感知**：脚本结束写状态文件与连续失败计数；连续失败 ≥4 天或描述文件剩余 <3 天视为临近失效，必须报警。通道按可用性选：

- Bark：iPhone 装 Bark 取 URL，脚本往该 URL POST 即推送（注意 api.day.app 不接受 GET 查询参数传 key，必须 JSON POST 或路径式）。
- 邮件：SMTP 授权码 + 简单发送脚本。
- macOS 通知：本机兜底，用户不在屏幕前无效。

信任一次绑定在开发证书上（1 年），刷新描述文件不需要重新“信任开发者”；**卸载 App 会清掉 App 内配对数据，要重新“添加连接”**，所以续签一律原地覆盖安装，不卸载。
