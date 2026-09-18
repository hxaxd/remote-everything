# 统一行为测试

三个客户端不是靠"看着像"统一，而是靠这份**共享 fixture + 每端消费它的测试**统一。

```
fixtures/
├── errors.json    线协议里每一个拒绝码 → 客户端该说的那句话的 key
├── nodes.json     两个网关的 /nodes 答案 → 合并后的节点行与选中的路径
├── paths.json     一组路径的可达/延迟/私网属性 → 该走哪条
├── catalog.json   一个 catalog 答案 → 那一页该显示什么状态
└── cadence.json   刷新与等待的节奏 → 三端同一种耐心（数字活在各自代码里，测试把它们钉在这儿）
```

规则：

- **key 是契约**，句子里不是。每端在自己的资源里把同一个 key 渲染成自己的语言与措辞；`MessageKeys`（各端一份，同名同值）是这些 key 的唯一出处。
- 每端在**自己的测试**里加载这些文件、断言自己的核心层得出同样的结论（同一句话的 key、同一行、同一条路径、同一个页面状态）。任何一端改了映射而没改 fixture，它的测试就会失败。
- fixture 只描述**结论**，不描述实现：语言不同、类型不同、写法不同都没关系，结论必须一致。
- 新增一个拒绝码、一个状态、一句话：先在 fixture 里出现，再三端各自实现，最后三端测试都过——这是"统一"这个词在这个仓库里的唯一含义。

各端入口：

| 端 | 测试位置 |
|----|----------|
| Android | `clients/android/app/src/test/java/com/remoteeverything/behavior/BehaviorFixturesTest.kt` |
| HarmonyOS | `clients/harmony/entry/src/ohosTest/...`（同一批 fixture，同一批断言） |
| iOS | `clients/ios/RemoteEverythingTests/BehaviorFixturesTests.swift` |
