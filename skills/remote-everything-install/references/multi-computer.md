# 多台电脑

**一台电脑 = 一个节点 = 一个全局唯一的 `node_id`**。网关是到达节点的路：它自己有一套身份、一份设备记录、一套信任，它认识的设备可以进它旗下的一台或多台节点。移动客户端先选节点、再看哪条路能到它。多台电脑因此有两种部署方式，按"要不要让它们共用一套信任"选。

## 一个网关，多台电脑（推荐）

一台服务器上的一个网关服务好几台电脑，每台电脑是一个节点：

1. 按 [install Skill](../SKILL.md) 的 public 流程建好网关（`init` 只建网关自己，不涉及节点）。
2. 每台电脑各自 `node init`，把 `node_id` 与 `listen_address` 交给 Agent。
3. 在网关上为每台电脑执行一次 `node add --name <名字> --node-id <该机器的 node_id> --node-bootstrap <该机器专属目录>`：它分配这台节点的隧道端口、签发这台节点独有的控制令牌、写出这台节点的交付目录。
4. 把交付目录送到那台电脑，`binding add --bootstrap` 导入身份；目录里的 `frpc/` 放到那台电脑的 `.runtime/state/frpc/<node_id>/`。
5. 在服务器上为每台节点渲染一份 frpc 配置并各起一个 frpc 进程（`node_host`/`node_port` 取那台电脑的 `listen_address`，`node_tunnel_port` 取 `node add` 输出里 `node_address` 的端口，`node_id` 取那台的 id——frps 用它在众多隧道里区分客户端）。
6. 重启网关（`node add` 对运行中的网关不生效），验证每台节点都 `computer_connected`。
7. `device invite --name <手机名> --node <某台节点>` 生成二维码；手机扫码配对、操作员 `approve`，然后 `device grant --node <另一台>` 把同一台手机追加授权到其余电脑上——不需要再扫一次码。

结果：手机上一个 Profile（一条路）下有多台电脑，`/__remote_everything/nodes` 就是它能进的那些；**Caddyfile 一个字都不用改**，443 入口与节点无关。

撤掉其中一台电脑：网关侧 `node remove --node <名字或 id>`（它会停止服务这台、删掉它的控制令牌、并从每个设备持有的名单里剔除），重启网关；那台机器上再 `binding remove <installation_id>` 并收拾掉它的隧道材料，健康检查那边用剩下的 `--tunnel-listen` 列表重跑一次 `install.sh`。这台电脑重新加入时是全新的身份令牌，不需要（也不应该）沿用旧的。

## 多台电脑，各自一个网关

要的是互相独立的信任域（例如一台机器给家人用、一台自己用），就让每台电脑各有一个网关：

1. 每台电脑按 public 流程走完整轮：自己的 `installation_id`、自己的设备 CA、自己的一组 loopback 端口（都是动态的，互不冲突）、自己的节点。
2. 服务器上已有 Caddy 在跑时，把新网关的路由**追加**到 Caddyfile，不要覆盖现有路由；每个网关在 Caddyfile 里是独立的一段站点块，上游指向它自己的 `status`/`pairing`/`frps` 端口。
3. 移动客户端会多出一个 Profile（同一个 origin、不同的安装身份）；在「连接管理」里切换。

一台电脑也可以同时挂在两个网关下：在那边照常 `node add` 一次即可（`binding add` 是追加的，节点接受任一绑定的令牌）。两条路各配对一次，各自的网关上各自审批、各自授权——这是"每台网关内部唯一"的代价，换来的是任何一侧都不需要相信另一侧。

## LAN 形态

一个 LAN 入口同样服务多台电脑：每台电脑 `node init --listen <该机器的局域网地址>`，入口侧 `node add --node-address <同一地址:端口>`。只要手机能访问入口端口（同网段或组网内），入口 `device invite --node <那台>` 发一条邀请、扫码添加即可——兑换即批准，不需要人工确认。

入口和节点同机时节点用缺省 loopback 监听；入口在另一台机器上时，节点 `--listen` 指向该机能被入口访问的地址，入口按同一个地址记录它。多个 LAN 入口之间完全独立。

## 移动客户端

- 一个 Profile = 一条路：一个 origin、要不要钉证书、自己的设备身份。
- 每个 Profile 下能看到这条路能到哪些节点（`/__remote_everything/nodes`），请求带上目标节点的 `X-Remote-Everything-Node`。
- 同一时间只有一个活跃 Profile（在目录页顶部显示当前连接名）。
- 切换 Profile：设置 → 管理连接 → 点击目标连接。
- 一条路对应的电脑离线，不影响其他路与其他节点。
