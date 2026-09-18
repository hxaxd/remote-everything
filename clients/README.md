# 三个客户端

三棵客户端树（`android/`、`ios/`、`harmony/`）是同一份设计的三种方言：**同一个模块地图，同一个命名，同一个职责落位**。共享的行为与线协议在 `behavior/` 与 `contracts/`，`behavior/fixtures/*.json` 是三端行为的仲裁者。

## 模块地图

三端照抄下面这张表：同名模块放同位置、承担同一职责。平台不得不不同的地方（密钥存储、WebView 宿主、扫描器）只在 `core/identity` 与 `app` 的宿主文件里，且每个都写明为什么别无选择。

```
app/                 平台壳：入口、AppModel（状态持有者 + 门面）、主题、i18n、屏幕
  <entry>            MainActivity / RemoteEverythingApp+AppRoot / EntryAbility+AppRoot
  AppModel           状态 + 生命周期 + web 目标解析 + 设置；轮询/配对等从它拆出控制器
  NodesController    节点列表刷新 + 状态推导 + 节点缓存（核心里无平台代码，网络环境注入）
  CatalogController  catalog 加载 + 应用开关 + control 轮询（退避、settle）
  PairingSession     两轮配对 + 暂存 + 审批轮询 + 兜底窗口
  theme/             Theme / AppTheme / Tokens
  i18n/              LocaleHelper / Localization / Strings
  ui/                屏幕：HomeScreen、PairScreen、NodeScreen、SettingsScreen、Components
  web/               Web 宿主与它的客户端（Android 是 Activity + WebView 回调，iOS 是 UIViewRepresentable，Harmony 是 ArkWeb）
core/
  model/             Models、MessageKeys、Cadence、ErrorCode+ClientError、Digest
  setup/             SetupUri（邀请解析）
  api/               Dto（严格解码）+ Client/Transport（连接池）+ Challenge/Pinning + Merge + CatalogOutcome
  identity/          Pkcs12、IdentityVault（平台密钥存储与 p12 导入只在这里）
  pairing/           PairingService + StagedSetup（暂存文件不含邀请 token）
  pathselect/        PathSelector（纯选择器）+ NetworkEnvironment（平台网络分类）
  store/             AtomicFile、SettingsStore、NodeCache
  update/            UpdateChecker（release 清单 + 判据）
  json/              Strict（wire 严格性规则；Android/iOS 各自的跨字段校验都在这）
```

## 规则

- 每个逻辑模块在两端叫同一个名字、放同一个包、干同一件事；新模块先改这张表再动手。
- 用户可见字符串只经 `MessageKeys`；key 集合与 `behavior/fixtures/message-keys.json` 逐一相等。
- 行为改动先改 `behavior/` 的 fixture，再三端实现，最后三端测试全绿才算完成。
- 平台必须差异（密钥、WebView、扫描器）隔离在 `core/identity` 与 `app/web`，并在文件注释里说明为什么没有更统一的写法。
