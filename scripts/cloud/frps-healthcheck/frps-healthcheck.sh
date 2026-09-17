#!/usr/bin/env bash
# Remote Everything frps 隧道健康检查（云端兜底）
#
# 本文件是模板：{{FRPS_ADDRESS}} / {{TUNNEL_ADDRESSES}} 由同目录 install.sh
# 在安装时按当前部署渲染替换，请勿直接运行仓库中的副本。
#
# 背景：本机 frpc <-> 云端 frps 的 FRP 隧道周期性楔死（frps 进程活着但
# 登录握手无响应），2026-07-23 / 08-03 / 08-05 三次复发，只能重启 frps 恢复。
# 本脚本兜底：定时探活，失败则重启 frps，目标是把故障时间压到分钟级。
#
# 看的是谁，才重启谁：动作是重启 frps，判据就必须落在 frps 上。
#   * frps 自己的端口都连不上 -> frps 不在了 -> 失败
#   * 所有节点的隧道都不通   -> 这条共享隧道断了，也就是 frps 楔死 -> 失败
#   * 只有部分节点不通       -> 是那几台机器自己不在线，与 frps 无关 -> 只记日志
# 最后一条是多节点下唯一能把"某台机器关机"和"frps 楔死"分开的判据：所有节点共用
# 同一个 frps，只有它们一起断才是 frps 的问题；只盯一台节点就会在它关机时反复重启
# 一台本来好好的 frps，还会把其余在线节点的隧道一起扯断。
#
# 判定逻辑（两层防误杀）：
#   * 探活失败后等待 5s 重试一次，两次都失败才动作（防瞬时抖动误杀）
#   * 连续失败才重启：第 1 次失败只记数，第 2 次失败才 systemctl restart，
#     并在重启成功后清零计数。启动初期/刚重启过的 frps 短暂失败不触发循环重启。
set -u

INSTALL_ID="{{INSTALLATION_ID}}"
FRPS_SERVICE="remote-everything-${INSTALL_ID}-frps"
FRPS_ADDRESS="{{FRPS_ADDRESS}}"
TUNNEL_ADDRESSES="{{TUNNEL_ADDRESSES}}"
PROBE_TIMEOUT=8
STATE_DIR="/var/lib/remote-everything/.runtime/state"
STATE_FILE="${STATE_DIR}/frps-health.json"
LOG_FILE="/var/lib/remote-everything/.runtime/logs/frps-health.log"
LOCK_FILE="/run/lock/remote-everything-frps-health.lock"
MAX_CONSECUTIVE_FAILURES=2

log() {
    printf '%s [healthcheck] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "$LOG_FILE"
}

# frps 自己的端口：TCP 连得上就说明它在这台机器上还在接受连接。这里要的只是连通性，
# 不是 HTTP —— 那个端口说的是 frp 协议，所以用 bash 的 /dev/tcp，不用 curl。
probe_frps() {
    timeout "$PROBE_TIMEOUT" bash -c "exec 3<>/dev/tcp/${FRPS_ADDRESS%:*}/${FRPS_ADDRESS##*:}" 2>/dev/null
}

# 一条隧道：探活成功返回 0；curl 退出码非 0 即失败（超时/拒连/5xx 都算）
probe_tunnel() {
    curl -fsS -o /dev/null --max-time "$PROBE_TIMEOUT" "http://$1/__remote_everything/apps"
}

# probe 是这次的判据：frps 自己不在，或它这条共享隧道整体不通，才算失败。
# 把结论写进 PROBE_DETAIL，供日志说明是谁的问题。
probe() {
    local address reachable=0 total=0
    if ! probe_frps; then
        PROBE_DETAIL="frps ${FRPS_ADDRESS} is not accepting connections"
        return 1
    fi
    for address in $TUNNEL_ADDRESSES; do
        total=$((total + 1))
        if probe_tunnel "$address"; then
            reachable=$((reachable + 1))
        else
            PROBE_DETAIL="${PROBE_DETAIL} ${address}"
        fi
    done
    if [ "$total" -eq 0 ]; then
        # 没有隧道可探（安装期要求至少一条，走到这里说明部署被手工改过）：那时
        # frps 自己在不在就是全部的判据。
        PROBE_DETAIL=""
        return 0
    fi
    if [ "$reachable" -eq 0 ]; then
        PROBE_DETAIL="frps ${FRPS_ADDRESS} answers but no tunnel through it does (${PROBE_DETAIL# })"
        return 1
    fi
    if [ "$reachable" -lt "$total" ]; then
        log "INFO: ${reachable}/${total} tunnels reachable; down:${PROBE_DETAIL} (that is those machines, not frps)"
    fi
    PROBE_DETAIL=""
    return 0
}

write_state() {
    local tmp="${STATE_FILE}.tmp"
    printf '{"consecutive_failures":%s}\n' "$1" > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

read_failures() {
    if [ -f "$STATE_FILE" ]; then
        grep -o '"consecutive_failures":[0-9]*' "$STATE_FILE" | cut -d: -f2 | tr -dc 0-9
    fi
}

# 并发保护：防止上一个探测还没跑完、下一个又进来（锁最长 4 分钟自动释放）
exec 9>"$LOCK_FILE"
flock -w 240 9 || { log "WARN: could not acquire lock (another run in progress?), skipping"; exit 0; }

mkdir -p "$STATE_DIR"
failures="$(read_failures)"
failures="${failures:-0}"
PROBE_DETAIL=""

if probe; then
    if [ "$failures" -ge 1 ]; then
        log "OK: frps and its tunnels are reachable (recovered), consecutive_failures was ${failures}, reset to 0"
    fi
    write_state 0
    exit 0
fi

failures=$((failures + 1))
write_state "$failures"
log "FAIL: $PROBE_DETAIL (attempt ${failures}/${MAX_CONSECUTIVE_FAILURES})"

if [ "$failures" -lt "$MAX_CONSECUTIVE_FAILURES" ]; then
    log "INFO: waiting 5s and retrying once before deciding"
    sleep 5
    if probe; then
        log "OK: reachable on retry, reset failures to 0"
        write_state 0
        exit 0
    fi
    failures=$((failures + 1))
    write_state "$failures"
    log "FAIL: retry also failed, $PROBE_DETAIL (attempt ${failures}/${MAX_CONSECUTIVE_FAILURES})"
fi

if [ "$failures" -lt "$MAX_CONSECUTIVE_FAILURES" ]; then
    log "SKIP: not enough consecutive failures yet, waiting for next tick"
    exit 0
fi

log "ACTING: restarting ${FRPS_SERVICE} because $PROBE_DETAIL"
systemctl restart "$FRPS_SERVICE"

sleep 5
if probe; then
    log "RECOVERED: ${FRPS_SERVICE} restarted, frps and its tunnels are reachable again"
else
    log "STILL-DOWN: restart done but $PROBE_DETAIL, will retry on next tick"
fi
write_state 0
exit 0
