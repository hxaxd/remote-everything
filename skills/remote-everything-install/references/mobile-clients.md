# 移动客户端取得方式

三端客户端必须与节点和入口使用同一项目标签。先查看 Release 说明是否提供该平台的正式资产或分发入口；没有时按下表处理。

| 平台 | 当前可交付方式 | 用户侧要求 |
|------|----------------|------------|
| Android | Release 中已签名的 `app-release.apk` | 校验 `SHA256SUMS` 后直接安装；升级时签名指纹必须与已安装版本一致 |
| iOS | 从目标标签源码本地构建 | 用户在 macOS 安装 Xcode 和 XcodeGen，生成工程后选择自己的开发团队与唯一 Bundle ID，连接设备完成签名安装 |
| HarmonyOS | 从目标标签源码本地构建 | 用户安装 DevEco Studio 与 HarmonyOS 6.0.1(21) SDK，配置自己的调试签名后构建并安装 HAP |

iOS 本地构建从 `clients/ios/` 执行 `xcodegen generate`，再打开生成的 `RemoteEverything.xcodeproj`。HarmonyOS 用 DevEco Studio 打开 `clients/harmony/`。具体开发依赖与验证命令以根目录 `CONTRIBUTING.md` 和目标标签中的工程声明为准。

Agent 可以检查源码、生成工程和指导构建，但不得索取、生成后带走或提交用户的 Apple/Huawei 开发证书、描述文件、私钥、密钥库和签名口令。签名材料不得写入 `.runtime/` 或 Git。没有用户自己的签名环境时，明确说明该平台客户端暂时无法安装，不用来源不明的 IPA/HAP，也不关闭平台签名校验。

将客户端来源、标签、取得方式和是否完成真机安装写入 `runtime.json` 的观测/验证记录；本地签名构建不视为项目官方分发包。
