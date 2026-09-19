# 移动客户端取得方式

三端客户端讲的都是现行协议：配对读取 `remote-everything://setup` URI，参数是 `node`、`node_name`、`origin`、`invitation`，可另带成对出现的 `fingerprint` 与 `public_key_pin`（见 `clients/contracts/schemas/setup-uri.schema.json`）；线上不携带版本、安装 ID 和模式，与网关 `device invite` 产出的邀请一致。

三端客户端必须与节点和入口使用同一项目标签。先查看 Release 说明是否提供该平台的正式资产或分发入口；没有时按下表处理。

| 平台 | 当前可交付方式 | 用户侧要求 |
|------|----------------|------------|
| Android | Release 中已签名的 `app-release.apk` | 校验 `SHA256SUMS` 后直接安装；升级时签名指纹必须与已安装版本一致 |
| iOS | 从目标标签源码本地构建 | 用户在 macOS 安装 Xcode 和 XcodeGen，生成工程后选择自己的开发团队与唯一 Bundle ID，连接设备完成签名安装 |
| HarmonyOS | 从目标标签源码本地构建 | 用户安装 DevEco Studio 与 HarmonyOS 6.1.1(24) SDK，配置自己的调试签名后构建并安装 HAP |

iOS 本地构建从 `clients/ios/` 执行 `xcodegen generate`，再打开生成的 `RemoteEverything.xcodeproj`。HarmonyOS 用 DevEco Studio 打开 `clients/harmony/`。具体开发依赖与验证命令以根目录 `CONTRIBUTING.md` 和目标标签中的工程声明为准。

Agent 可以检查源码、生成工程和指导构建，但不得索取、生成后带走或提交用户的 Apple/Huawei 开发证书、描述文件、私钥、密钥库和签名口令。签名材料不得写入 `.runtime/` 或 Git。没有用户自己的签名环境时，明确说明该平台客户端暂时无法安装，不用来源不明的 IPA/HAP，也不关闭平台签名校验。

将客户端来源、标签、取得方式和是否完成真机安装写入 `runtime.json` 的观测/验证记录；本地签名构建不视为项目官方分发包。

## 改动客户端之后：最少验什么

三端共享 `clients/behavior/fixtures/` 里的行为契约（消息键、选路、节点、路径、错误码、cadence、web 偏好）：改行为先改夹具，三端各自的测试读同一批字节。除此之外：

- **Android**：`./gradlew :app:testDebugUnitTest`（夹具 + 契约 + 选路），`:app:assembleDebug` 出包；正式签名包走 `scripts/release-local.ps1`。
- **iOS**：**只能在 macOS 上编译与测试**——`xcodegen generate` 之后 `xcodebuild test`（模拟器）+ `xcodebuild analyze`。没有 mac 就不要说“已验证”。
- **HarmonyOS**：`hvigorw assembleHap --mode module -p product=default -p module=entry@default --no-daemon --type-check`，**再加一次 `-p module=entry@ohosTest`**——改过 `Dto`/导出面之后，只编主模块会漏掉测试模块里的构造调用（同一个编译还不算完，两个 target 都要过）。套件在 `entry/src/ohosTest`，是插桩测试，要真机或模拟器；hvigor 自带的 `test` 任务是宿主侧模式，需要本仓库没有的 `entry/src/test/`，不要用它。

两条界面约定（都踩过）：Android targetSdk 36 起强制 edge-to-edge，自绘界面的控件必须吃 window insets，否则状态栏那一条的触摸归通知栏、按钮点不到；Android 13+ 不要指望系统剪贴板提示（部分 ROM 不弹），复制反馈一律由应用自己给。
