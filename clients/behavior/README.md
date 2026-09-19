# 统一行为测试

三个客户端不是靠"看着像"统一，而是靠这份**共享 fixture + 每端消费它的测试**统一。

```
fixtures/
├── errors.json        线协议里每一个拒绝码 → 客户端该说的那句话的 key
├── nodes.json         两个网关的 /nodes 答案 → 合并后的节点行与选中的路径
├── paths.json         一组路径的可达/延迟/私网属性 → 该走哪条
├── catalog.json       一个 catalog 答案 → 那一页该显示什么状态
├── cadence.json       刷新与等待的节奏 → 三端同一种耐心（数字活在各自代码里，测试把它们钉在这儿）
├── message-keys.json  三端共用的一套用户可见字符串 key → 每端 MessageKeys 常量集、资源键集都与它逐一相同
├── web-app-prefs.json 每个应用的 Web 宿主偏好（屏幕方向、标识）的取值词表与默认值 → 三端同一套词、同一个默认
└── wire-cases.json    线协议严格性用例（跨字段规则、取值集、长度/字符限制）→ 三端各自用严格解码器跑同一个判据
```

规则：

- **key 是契约**，句子里不是。每端在自己的资源里把同一个 key 渲染成自己的语言与措辞；`MessageKeys`（各端一份，同名同值）是这些 key 的唯一出处。`message-keys.json` 钉住这套 key 本身：各端测试断言自己的常量集 == fixture、资源键集 == 常量集。
- 每端在**自己的测试**里加载这些文件、断言自己的核心层得出同样的结论（同一句话的 key、同一行、同一条路径、同一个页面状态）。任何一端改了映射而没改 fixture，它的测试就会失败。
- fixture 只描述**结论**，不描述实现：语言不同、类型不同、写法不同都没关系，结论必须一致。
- 新增一个拒绝码、一个状态、一句话：先在 fixture 里出现，再三端各自实现，最后三端测试都过——这是"统一"这个词在这个仓库里的唯一含义。

行为约定（写进代码、也写进这里的承诺）：

- **忘记一个网关**：删除它的身份、节点记录、待批准配对与节点缓存；**不动任何 web 数据**。每应用独立 origin 已经让各应用/各网关的浏览器状态互不可见，而身份一删这些 origin 也无法再打开，所以残留的数据是惰性的——三端统一为"不清理"，而不是三套清理姿势。
- **每个应用的 Web 宿主偏好**：一个应用的方向与标识（`web-app-prefs.json` 钉住词表与默认值）按 `nodeId/appId` 记忆，只影响那一个应用的下一次打开；默认是跟随系统 + 移动标识，且从不写入任何线协议字段。
- **未决配对的窗口**：窗口就是配对应答里的 `pending_expires_at`，暂存配对活到这一刻为止；`pending_expires_at` 读不懂时整个配对被严格解码拒绝（`wire-cases.json` 钉死），不存在"读不懂就自己估一个窗口"的路径。审批轮询窗口（`approvalPollTimeoutMs`）走完后三端都只是停止轮询、保留待批状态：操作员随时可能批准，重新拉起即恢复。

各端入口：

| 端 | 测试位置 |
|----|----------|
| Android | `clients/android/app/src/test/java/com/remoteeverything/behavior/BehaviorFixturesTest.kt` |
| HarmonyOS | `clients/harmony/entry/src/ohosTest/...`（同一批 fixture，同一批断言） |
| iOS | `clients/ios/RemoteEverythingTests/BehaviorFixturesTests.swift` |
