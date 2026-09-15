#!/usr/bin/env bash
# Remote Everything frps 隧道健康检查（云端兜底）
#
# 本文件是模板：{{INSTALLATION_ID}} / {{PROBE_URL}} 由同目录 install.sh
# 在安装时按当前部署的 server.json 渲染替换，请勿直接运行仓库中的副本。
#
# 背景：本机 frpc <-> 云端 frps 的 FRP 隧道周期性楔死（frps 进程活着但
# 登录握手无响应），2026-07-23 / 08-03 / 08-05 三次复发，只能重启 frps 恢复。
# 本脚本兜底：定时探活隧道端口，失败则重启 frps，目标是把故障时间压到分钟级。
#
# 判定逻辑（两层防误杀）：
#   * 探活失败后等待 5s 重试一次，两次都失败才动作（防瞬时抖动误杀）
#   * 连续失败才重启：第 1 次失败只记数，第 2 次失败才 systemctl restart，
#     并在重启成功后清零计数。启动初期/刚重启过的 frps 短暂失败不触发循环重启。
set -u

INSTALL_ID="{{INSTALLATION_ID}}"
FRPS_SERVICE="remote-everything-${INSTALL_ID}-frps"
PROBE_URL="{{PROBE_URL}}"
PROBE_TIMEOUT=8
STATE_DIR="/var/lib/remote-everything/.runtime/state"
STATE_FILE="${STATE_DIR}/frps-health.json"
LOG_FILE="/var/lib/remote-everything/.runtime/logs/frps-health.log"
LOCK_FILE="/run/lock/remote-everything-frps-health.lock"
MAX_CONSECUTIVE_FAILURES=2

log() {
    printf '%s [healthcheck] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >> "$LOG_FILE"
}

probe() {
    # 探活成功返回 0；curl 退出码非 0 即失败（超时/拒连/5xx 都算）
    curl -fsS -o /dev/null --max-time "$PROBE_TIMEOUT" "$PROBE_URL"
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

if probe; then
    if [ "$failures" -ge 1 ]; then
        log "OK: tunnel reachable (recovered), consecutive_failures was ${failures}, reset to 0"
    fi
    write_state 0
    exit 0
fi

failures=$((failures + 1))
write_state "$failures"
log "FAIL: tunnel probe failed (attempt ${failures}/${MAX_CONSECUTIVE_FAILURES})"

if [ "$failures" -lt "$MAX_CONSECUTIVE_FAILURES" ]; then
    log "INFO: waiting 5s and retrying once before deciding"
    sleep 5
    if probe; then
        log "OK: tunnel reachable on retry, reset failures to 0"
        write_state 0
        exit 0
    fi
    failures=$((failures + 1))
    write_state "$failures"
    log "FAIL: retry probe also failed (attempt ${failures}/${MAX_CONSECUTIVE_FAILURES})"
fi

if [ "$failures" -lt "$MAX_CONSECUTIVE_FAILURES" ]; then
    log "SKIP: not enough consecutive failures yet, waiting for next tick"
    exit 0
fi

log "ACTING: restarting ${FRPS_SERVICE}"
systemctl restart "$FRPS_SERVICE"

sleep 5
if probe; then
    log "RECOVERED: ${FRPS_SERVICE} restarted, tunnel reachable again"
else
    log "STILL-DOWN: restart done but probe still failing, will retry on next tick"
fi
write_state 0
exit 0
