# 三端客户端架构与发布计划

本文固定 Android、iOS、HarmonyOS 三端的共同边界、目录映射和发布验收。具体协议以 `clients/contracts/` 为准，平台代码不得自行放宽安全条件。

## 目标结构

```text
clients/
├── contracts/              # 共享 Schema、正反例夹具与契约校验
├── android/                # Kotlin + Jetpack Compose + Android WebView
├── ios/                    # Swift + SwiftUI + WKWebView
├── harmony/                # ArkTS + ArkUI + ArkWeb
├── release.json            # 三端共同版本与协议版本
└── validate_versions.py    # 版本一致性门禁
```

各端保持相同的功能分层：`models`、`network`、`security`、`storage`、`update`、`setup`、`catalog`、`connections`、`settings`、`remote web`。平台原生入口和资源文件保留各自惯例，不复制服务端业务逻辑。

## 共同契约

- setup URI 使用协议 v2；LAN 同时携带证书指纹与公钥摘要，public 携带单次邀请。
- 每台电脑对应一个 `installationId` 和一个 Profile；客户端同一时间只有一个活动 Profile。
- public 配对严格执行 invitation → pending credential → 人工批准 → mTLS activation → active credential。
- LAN 请求必须固定网关身份；public 请求必须使用系统信任链和活动设备证书。
- 目录、控制、激活响应按共享 Schema 严格解码，拒绝未知字段和状态矛盾。
- 路由 Cookie 必须在首次页面导航前写入；外部来源不得继承客户端证书或路由状态。
- 文件选择、下载、相机、麦克风、弹窗、全屏和外部链接都通过平台原生能力受控转发。

## 平台映射

| 能力 | Android | iOS | HarmonyOS |
|---|---|---|---|
| 安全存储 | Android Keystore / app storage | Keychain | Asset Store / app sandbox |
| 原生网络 | HTTPS + certificate pinning + mTLS | URLSession + Security | Network Kit + certificate pinning + mTLS |
| Web 容器 | Android WebView | WKWebView | ArkWeb |
| 文件选择 | Storage Access Framework | 系统文件/照片选择器 | DocumentViewPicker |
| 更新入口 | 签名 APK 安装 | 正式分发页 | 正式分发页 |
| 工程验证 | Gradle test/lint/build | XcodeGen + xcodebuild test/analyze | DevEco/Hvigor + 源码门禁 |

## 已确认的平台边界

- iOS 17 起由 WKWebView 沿用 Safari 的系统文件上传界面；客户端不覆盖该流程，也不注入网页私有接口。
- HarmonyOS 6.1.1 的 ArkWeb 仅提供应用进程级的普通与无痕 Cookie/WebStorage 存储，没有 Android WebView Profile 或 iOS `WKWebsiteDataStore` 对应的按 `installationId × appId` 持久化资料域。当前实现优先保证应用间隔离：进入远程应用前清空无痕存储并禁用网页缓存，因此退出后不承诺保留网页会话。
- 在 ArkWeb 提供可独立持久化的资料域前，HarmonyOS 不同时打开两个远程 Web 页面，也不以导出 Cookie、注入 localStorage 或复用全局持久化存储的方式模拟隔离。内嵌多窗口与 `blob:` 下载同样保持关闭，避免形成不可验证的跨应用数据通道。

## 发布门禁

1. `clients/contracts/validate_contracts.py` 和 `clients/validate_versions.py` 通过。
2. Android 单元测试、lint、debug build 通过，APK 不含部署凭据。
3. iOS 在 macOS 上生成 Xcode 工程，完成单元测试、覆盖率采集和静态分析。
4. HarmonyOS 在 DevEco Studio 配置的 HarmonyOS 6.1.1(24) SDK 上完成 type check、测试与 HAP 构建；本地发布脚本必须解析真实测试结果，不能只采用 Hvigor 退出码。
5. 三端真机验证 LAN/public 初始化、重启恢复、连接切换、目录刷新、应用启停、Web 会话、上传下载、媒体权限、返回手势和暗色模式。
6. 发布前运行完整历史秘密扫描、依赖许可证清单和 SBOM，并确认签名材料只存在于受保护的发布环境。

## 分发策略

- Android 由 GitHub Release 发布签名 APK 和 SHA-256 校验文件。
- iOS 使用 Apple 支持的测试或正式分发方式，仓库不保存签名证书与描述文件。
- HarmonyOS 使用 AppGallery Connect 或受支持的内部测试分发，仓库不保存发布证书、Profile 或密钥库。
- 三端使用同一个语义版本和内部构建号；任一平台未通过对应门禁时，不标记为完整三端发布。
