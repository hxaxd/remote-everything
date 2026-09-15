#!/usr/bin/env bash
# Remote Everything frps 健康检查：云端标准安装入口。
#
# 把 frps-healthcheck.sh 模板安装到指定目录，按当前部署渲染三处占位符：
#   {{HEALTHCHECK_SCRIPT}} -> 脚本实际绝对路径（写入 systemd 单元 ExecStart）
#   {{INSTALLATION_ID}}    -> 当前部署的 installation_id（决定要重启的 frps 服务名）
#   {{PROBE_URL}}          -> http://<node_tunnel_listen>/__remote_everything/apps
# 然后安装 service/timer 单元并启用定时器。
# 单元不再硬编码 /usr/local/bin，脚本装在哪里都能正常启动；每个部署独立渲染。
#
# 用法:
#   sudo ./install.sh --installation-id HEX64 --node-tunnel-listen 127.0.0.1:PORT
#                     [--target-dir DIR] [--unit-dir DIR] [--no-enable]
#
# 取值来源（标准安装流程，见 skills/remote-everything-install）:
#   installation_id     网关 init 输出（runtime.json / server.json 同一 ID）
#   node_tunnel_listen  服务端 server.json 的 node_tunnel_listen（loopback 地址）
set -euo pipefail

SCRIPT_NAME="frps-healthcheck.sh"
SERVICE_NAME="remote-everything-frps-healthcheck.service"
TIMER_NAME="remote-everything-frps-healthcheck.timer"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/usr/local/bin"
UNIT_DIR="/etc/systemd/system"
ENABLE=1
INSTALLATION_ID=""
NODE_TUNNEL_LISTEN=""

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --installation-id) INSTALLATION_ID="${2:-}"; shift 2 ;;
        --node-tunnel-listen) NODE_TUNNEL_LISTEN="${2:-}"; shift 2 ;;
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
[[ "$NODE_TUNNEL_LISTEN" =~ ^127\.0\.0\.1:[0-9]{2,5}$ ]] \
    || die "--node-tunnel-listen 必须是 127.0.0.1:PORT 形式（取自 server.json）"
port="${NODE_TUNNEL_LISTEN##*:}"
[ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || die "探活端口越界: $port"
case "$TARGET_DIR" in /*) ;; *) die "脚本安装目录必须是绝对路径: $TARGET_DIR" ;; esac
case "$UNIT_DIR" in /*) ;; *) die "systemd 单元目录必须是绝对路径: $UNIT_DIR" ;; esac

SCRIPT_PATH="$TARGET_DIR/$SCRIPT_NAME"
PROBE_URL="http://$NODE_TUNNEL_LISTEN/__remote_everything/apps"
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
trap 'rm -f "$installed_script" "$rendered_service"' EXIT

cp "$SRC_DIR/$SCRIPT_NAME" "$installed_script"
render "{{INSTALLATION_ID}}" "$INSTALLATION_ID" "$installed_script"
render "{{PROBE_URL}}" "$PROBE_URL" "$installed_script"
cp "$SRC_DIR/$SERVICE_NAME" "$rendered_service"
render "{{INSTALLATION_ID}}" "$INSTALLATION_ID" "$rendered_service"
render "{{HEALTHCHECK_SCRIPT}}" "$SCRIPT_PATH" "$rendered_service"

# ---- 渲染结果校验（任何占位符残留或内容不符都拒绝安装）----
if grep -qE '\{\{[A-Z_]+\}\}' "$installed_script" "$rendered_service"; then
    echo "渲染失败：仍存在未替换的占位符" >&2
    grep -nE '\{\{[A-Z_]+\}\}' "$installed_script" "$rendered_service" >&2 || true
    exit 1
fi
grep -qxF "INSTALL_ID=\"$INSTALLATION_ID\"" "$installed_script" \
    || die "脚本渲染校验失败：INSTALL_ID 不匹配"
grep -qxF "PROBE_URL=\"$PROBE_URL\"" "$installed_script" \
    || die "脚本渲染校验失败：PROBE_URL 不匹配"
grep -qxF "ExecStart=$SCRIPT_PATH" "$rendered_service" \
    || die "单元渲染校验失败：期望 ExecStart=$SCRIPT_PATH"
grep -qxF "After=remote-everything-$INSTALLATION_ID-frps.service" "$rendered_service" \
    || die "单元渲染校验失败：After 与 installation_id 不匹配"
bash -n "$installed_script" || die "渲染后脚本语法检查失败"

install -m 0755 "$installed_script" "$SCRIPT_PATH"
install -m 0644 "$rendered_service" "$UNIT_DIR/$SERVICE_NAME"
install -m 0644 "$SRC_DIR/$TIMER_NAME" "$UNIT_DIR/$TIMER_NAME"

# verify 目标文件名（报错前缀才会是服务名）；其他单元的既有告警不含本服务名
if systemd-analyze verify "$UNIT_DIR/$SERVICE_NAME" 2>&1 | grep -qF "$SERVICE_NAME"; then
    die "systemd-analyze verify 报告单元错误，未启用定时器"
fi

echo "已安装脚本:   $SCRIPT_PATH  (installation_id=$INSTALLATION_ID, probe=$PROBE_URL)"
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
