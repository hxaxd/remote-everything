# Public FRPS 健康检查

仅用于 Linux public 部署；检查 FRPS 监听与每台节点的回环隧道。安装入口：

```text
scripts/cloud/frps-healthcheck/install.sh --installation-id <64位ID> --frps-listen <init 的 frps_listen> --tunnel-listen <node list 的 address，一台一次>
```

安装器读取同目录模板、替换路径和地址、验证脚本与单元，再启用定时器。至少有一台节点时安装；空网关先保留入口服务，第一台节点加入后启用检查。最后一个节点移除时停用该 timer，避免继续探测已撤销地址。重装相同 ID 只更新该实例；加删节点或 `ports repair` 后，用当前完整节点名单重装。`--no-enable` 可只生成并验证产物。

更新组件管理布局时，先对照 runtime 中本实例已登记的集成，停用并移除目标布局不再使用的受管定义，再安装并记录新产物；不能仅新增定时器而留下另一套检查继续运行，也不能按全局名字删除其它实例的对象。

令 `<base>` 为 `remote-everything-<installation_id>-frps-healthcheck`，默认产物如下：

| 对象 | 路径或名称 |
| --- | --- |
| 检查脚本 | `/usr/local/bin/<base>.sh` |
| 检查服务 | `/etc/systemd/system/<base>.service` |
| 定时器 | `/etc/systemd/system/<base>.timer`，显式指向同实例 service |
| 状态 | `/var/lib/remote-everything/frps-healthcheck/<installation_id>/state.json` |
| 日志 | 同一数据目录下的 `health.log` |
| 锁 | `/run/lock/<base>.lock` |

可用 `--target-dir`、`--unit-dir`、`--data-dir`、`--lock-dir` 指定安装位置；脚本/单元/锁的文件名及数据子目录始终含完整 installation ID。将安装器输出的实际路径、service/timer 名称与 owner 记为该网关 runtime 中的受管集成，不能依靠全局文件名发现它们。非默认单元目录不自动启用。

验收时检查该实例 timer 的 `enabled/active`，手动启动其 service，核对 `Result/ExecMainStatus`、实际脚本、监听地址、完整节点名单和 `health.log`。状态计数、日志和互斥锁只属于该实例。现有恢复判据仍是：FRPS TCP 不通，或所有隧道都不通时连续复核并重启；部分隧道不通只记日志。所有节点关机也可能满足“所有隧道不通”，该恢复启发式不能证明 FRPS 自身故障。

移除某网关时，先 `disable --now` 它自己的 timer，再停止其检查 service；仅删除运行记录内该实例的脚本、service/timer、数据目录和锁文件，最后 `daemon-reload`。只重建 FRPS 时保留检查集成，按该实例现有参数重装。其它 installation ID 的检查产物保留。
