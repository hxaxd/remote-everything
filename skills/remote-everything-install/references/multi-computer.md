# 多台电脑

一台电脑 = 一个 installationId = 移动客户端上一个 Profile。多台电脑各自部署独立实例，移动设备扫码添加后手动切换。

**每台电脑的过程和首次部署完全一样**——唯一的区别是服务器上已有 Caddy 在跑，只需追加一段路由。

## 公网形态（同一台 Linux 服务器）

已有部署：服务器上 Caddy 已占 443，至少一个 gateway/frps 在跑。

新电脑加入：

1. 按 [install Skill](../SKILL.md) 的 public 流程走完整轮，唯一的区别是 Caddy 已经存在——把新 gateway 的路由**追加**到 Caddyfile，不要覆盖现有路由。
2. `gateway init --node-bootstrap` 会生成新的 installationId 和独立的 loopback 端口组，不与已有 gateway 冲突。
3. 把 bootstrap bundle 送到新电脑，完成节点初始化。
4. `device invite` 生成新二维码，移动客户端扫码后批准。
5. 客户端的 Profile 列表会多出一条。在「连接管理」里切换即可。

结果：两台电脑各自的 gateway 共享一个 Caddy:443，Android、iOS 与 HarmonyOS 客户端都通过切换 Profile 选择连接实例。

## LAN 形态

每台电脑运行自己的 `server/lan` + node。只要移动设备能访问它们的入口端口（同网段或组网内），扫码添加即可。多个 LAN 实例之间完全独立。

## 移动客户端

- 每个 Profile 保存了一个 installationId 对应的网关地址、模式和证书指纹/设备身份。
- 同一时间只有一个活跃 Profile（在目录页顶部显示当前连接名）。
- 切换 Profile：设置 → 管理连接 → 点击目标连接。
- 一个 Profile 对应的电脑离线，不影响其他 Profile。
