#!/usr/bin/env bash
# Remote Everything frps 健康检查：云端标准安装入口。
#
# 把 frps-healthcheck.sh 模板安装到指定目录，按当前部署渲染四处占位符：
#   {{HEALTHCHECK_SCRIPT}} -> 脚本实际绝对路径（写入 systemd 单元 ExecStart）
#   {{INSTALLATION_ID}}    -> 当前部署的 installation_id（决定要重启的 frps 服务名）
#   {{FRPS_ADDRESS}}       -> frps 自己的监听地址（gateway init 输出的 frps_listen）
#   {{TUNNEL_ADDRESSES}}   -> 每台节点的隧道地址（gateway node list 里各台的 node_address）
# 然后安装 service/timer 单元并启用定时器。
# 单元不再硬编码 /usr/local/bin，脚本装在哪里都能正常启动；每个部署独立渲染。
#
# 用法:
#   sudo ./install.sh --installation-id HEX64 --frps-listen 127.0.0.1:PORT
#                     --tunnel-listen 127.0.0.1:PORT [--tunnel-listen 127.0.0.1:PORT ...]
#                     [--target-dir DIR] [--unit-dir DIR] [--no-enable]
#
# 重启的是 frps，所以判据落在 frps 上：探 frps 自己的端口，以及每条穿过它的隧道。
# frps 不在，或者所有隧道一起断（它们共用这一个 frps，一起断就是它的问题）才重启；
# 只有部分隧道断，说明是那几台节点自己不在线，与 frps 无关，只记日志。
# 多台节点时把每一台的 node_address 都给出来：只给一台，那台关机就会被当成 frps 楔死。
#
# 取值来源（标准安装流程，见 skills/remote-everything-install）:
#   installation_id   网关 init 输出（runtime.json / server.json 同一 ID）
#   frps_listen       网关 init 输出的 frps_listen（loopback）
#   node_address      每台节点：gateway node list 输出里的 node_address（loopback）
set -euo pipefail

SCRIPT_NAME="frps-healthcheck.sh"
SERVICE_NAME="remote-everything-frps-healthcheck.service"
TIMER_NAME="remote-everything-frps-healthcheck.timer"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
ENABLE=1
INSTALLATION_ID=""
FRPS_LISTEN=""
TUNNEL_LISTENS=()

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --installation-id) INSTALLATION_ID="${2:-}"; shift 2 ;;
        --frps-listen) FRPS_LISTEN="${2:-}"; shift 2 ;;
        --tunnel-listen) TUNNEL_LISTENS+=("${2:-}"); shift 2 ;;
        --target-dir) TARGET_DIR="${2:-}"; shift 2 ;;
        --unit-dir) UNIT_DIR="${2:-}"; shift 2 ;;
        --no-enable) ENABLE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数: $1（用 --help 查看用法）" >&2; exit 2 ;;
    esac
done

die() { echo "$*" >&2; exit 2; }

# ---- 入参校验 ----
[[ "$INSTALLATION_ID" =~ ^[0-9a-f]{64}$ ]] \
    || die "必须用 --installation-id 传入 64 位十六进制 installation_id"

loopback_port() { # 取值来源只能是 loopback:PORT，并检查端口范围
    local value="$1" name="$2" port
    [[ "$value" =~ ^127\.0\.0\.1:[0-9]{2,5}$ ]] \
        || die "$name 必须是 127.0.0.1:PORT 形式（取自 gateway init / node list 的 loopback 地址）"
    port="${value##*:}"
    [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "$name 探活端口越界: $port"
    printf '%s' "$value"
}

[ -n "$FRPS_LISTEN" ] || die "必须用 --frps-listen 传入 frps 自己的监听地址（gateway init 的 frps_listen）"
FRPS_LISTEN="$(loopback_port "$FRPS_LISTEN" "--frps-listen")"
[ "${#TUNNEL_LISTENS[@]}" -ge 1 ] || die "必须至少用一个 --tunnel-listen 传入一条节点隧道地址（gateway node list 的 node_address）"
TUNNEL_ADDRESSES=""
for index in "${!TUNNEL_LISTENS[@]}"; do
    address="$(loopback_port "${TUNNEL_LISTENS[$index]}" "--tunnel-listen")"
    TUNNEL_LISTENS[index]="$address"
    TUNNEL_ADDRESSES="${TUNNEL_ADDRESSES:+$TUNNEL_ADDRESSES }$address"
done
case "$TARGET_DIR" in /*) ;; *) die "脚本安装目录必须是绝对路径: $TARGET_DIR" ;; esac
case "$UNIT_DIR" in /*) ;; *) die "systemd 单元目录必须是绝对路径: $UNIT_DIR" ;; esac

SCRIPT_PATH="$TARGET_DIR/$SCRIPT_NAME"
# systemd 命令行无法加引号兜底，空白等特殊字符会导致单元解析失败，提前拒绝
case "$SCRIPT_PATH" in
    *[[:space:]\"]*|*\'*) die "脚本路径不允许含空白或引号: $SCRIPT_PATH" ;;
esac

# ---- 渲染：把占位符替换为实际值（| 不会出现在这些值中；转义 & 与反斜杠）----
render() {
    local placeholder="$1" value="$2" file="$3"
    local escaped="${value//\\/\\\\}"
    escaped="${escaped//&/\\&}"
    sed -i "s|$placeholder|$escaped|g" "$file"
}

mkdir -p "$TARGET_DIR" "$UNIT_DIR"
installed_script="$(mktemp)"
rendered_service="$(mktemp)"
installed_timer="$(mktemp)"
trap 'rm -f "$installed_script" "$rendered_service" "$installed_timer"' EXIT

# 模板一律按 LF 装出去：systemd 读的是这两个单元，CRLF 会让它解析失败，而从
# Windows 侧 checkout 或拷贝过来的工作副本很容易带 CRLF。
copy_lf() { tr -d '\r' < "$1" > "$2"; }

copy_lf "$SRC_DIR/$SCRIPT_NAME" "$installed_script"
render "{{INSTALLATION_ID}}" "$INSTALLATION_ID" "$installed_script"
render "{{FRPS_ADDRESS}}" "$FRPS_LISTEN" "$installed_script"
render "{{TUNNEL_ADDRESSES}}" "$TUNNEL_ADDRESSES" "$installed_script"
copy_lf "$SRC_DIR/$SERVICE_NAME" "$rendered_service"
render "{{INSTALLATION_ID}}" "$INSTALLATION_ID" "$rendered_service"
render "{{HEALTHCHECK_SCRIPT}}" "$SCRIPT_PATH" "$rendered_service"
copy_lf "$SRC_DIR/$TIMER_NAME" "$installed_timer"

# ---- 渲染结果校验（任何占位符残留、行尾或内容不符都拒绝安装）----
if grep -qE '\{\{[A-Z_]+\}\}' "$installed_script" "$rendered_service"; then
    echo "渲染失败：仍存在未替换的占位符" >&2
    grep -nE '\{\{[A-Z_]+\}\}' "$installed_script" "$rendered_service" >&2 || true
    exit 1
fi
if grep -qU $'\r' "$installed_script" "$rendered_service" "$installed_timer"; then
    die "渲染失败：装出去的文件含 CR，systemd 与 bash 都读不了"
fi
grep -qxF "INSTALL_ID=\"$INSTALLATION_ID\"" "$installed_script" \
    || die "脚本渲染校验失败：INSTALL_ID 不匹配"
grep -qxF "FRPS_ADDRESS=\"$FRPS_LISTEN\"" "$installed_script" \
    || die "脚本渲染校验失败：FRPS_ADDRESS 不匹配"
grep -qxF "TUNNEL_ADDRESSES=\"$TUNNEL_ADDRESSES\"" "$installed_script" \
    || die "脚本渲染校验失败：TUNNEL_ADDRESSES 不匹配"
grep -qxF "ExecStart=$SCRIPT_PATH" "$rendered_service" \
    || die "单元渲染校验失败：期望 ExecStart=$SCRIPT_PATH"
grep -qxF "After=remote-everything-$INSTALLATION_ID-frps.service" "$rendered_service" \
    || die "单元渲染校验失败：After 与 installation_id 不匹配"
bash -n "$installed_script" || die "渲染后脚本语法检查失败"

install -m 0755 "$installed_script" "$SCRIPT_PATH"
install -m 0644 "$rendered_service" "$UNIT_DIR/$SERVICE_NAME"
install -m 0644 "$installed_timer" "$UNIT_DIR/$TIMER_NAME"

# verify 目标文件名（报错前缀才会是服务名）；其他单元的既有告警不含本服务名
if systemd-analyze verify "$UNIT_DIR/$SERVICE_NAME" 2>&1 | grep -qF "$SERVICE_NAME"; then
    die "systemd-analyze verify 报告单元错误，未启用定时器"
fi

echo "已安装脚本:   $SCRIPT_PATH  (installation_id=$INSTALLATION_ID, frps=$FRPS_LISTEN, tunnels=$TUNNEL_ADDRESSES)"
echo "已安装单元:   $UNIT_DIR/$SERVICE_NAME"
echo "已安装定时器: $UNIT_DIR/$TIMER_NAME"

if [ "$ENABLE" -eq 1 ] && [ "$UNIT_DIR" = "/etc/systemd/system" ]; then
    systemctl daemon-reload
    systemctl enable --now "$TIMER_NAME"
    echo "已启用定时器: $TIMER_NAME"
    systemctl is-active "$TIMER_NAME"
else
    echo "已跳过自动启用（--no-enable 或非默认单元目录），请手动 daemon-reload/enable"
fi
