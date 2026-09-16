#!/usr/bin/env bash
set -euo pipefail

harness_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
node_root=$1
suite=$2
temp_root=$(mktemp -d)
control_pid=
cleanup() {
  if [[ -n "$control_pid" ]]; then kill -KILL "$control_pid" 2>/dev/null || true; fi
  rm -rf -- "$temp_root"
}
trap cleanup EXIT

fail() { echo "assertion failed: $*" >&2; exit 1; }
assert_json() {
  python3 -c "import json,sys; value=json.load(sys.stdin); assert $1" || fail "$2"
}
free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}
port_open() {
  python3 - "$1" <<'PY'
import socket
import sys
with socket.socket() as sock:
    sock.settimeout(0.1)
    raise SystemExit(0 if sock.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)
PY
}
dump_logs() {
  if [[ -d "${state_root:-}/logs" ]]; then
    for log in "$state_root"/logs/*; do
      [[ -f "$log" ]] || continue
      printf '%s\n' "$log"
      sed -n '1,160p' "$log"
    done >&2
  fi
  ps -axo pid=,ppid=,pgid=,state=,command= | grep -F "$temp_root" >&2 || true
  ps -axo pid=,ppid=,pgid=,state=,command= | grep -F "$harness_dir/fixture_server.py" >&2 || true
}
wait_port() {
  local port=$1 expected=$2 stage=$3
  for _ in {1..100}; do
    if port_open "$port"; then actual=open; else actual=closed; fi
    [[ "$actual" == "$expected" ]] && return
    sleep 0.1
  done
  dump_logs
  fail "$stage port $port did not become $expected"
}
control() {
  curl -sS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data "$1" "http://127.0.0.1:$control_port/__local_remote_control"
}

command -v python3 >/dev/null || fail 'python3 is required'
command -v curl >/dev/null || fail 'curl is required'

app_port=$(free_port)
state_root="$temp_root/state"
repo_root=$(CDPATH= cd -- "$harness_dir/../../.." && pwd)
token=$(printf '01%.0s' {1..32})
installation_id=$(printf '02%.0s' {1..32})
command -v go >/dev/null || fail 'Go compiler is required (genbundle is built alongside the control binary)'
if [[ -n "${CONTROL_BINARY:-}" ]]; then
  cp "$CONTROL_BINARY" "$temp_root/control"
  chmod +x "$temp_root/control"
else
  (cd "$node_root" && go build -o "$temp_root/control" .)
fi
(cd "$repo_root" && go build -o "$temp_root/genbundle" ./internal/nodecore/testharness/genbundle)
init_json=$("$temp_root/control" init --state "$state_root")
printf '%s' "$init_json" | assert_json 'value["ok"] and len(value["node_id"]) == 64' 'init creates node state'
"$temp_root/control" init --state "$state_root" | assert_json 'value["ok"]' 'init is idempotent'
"$temp_root/genbundle" -gateway "$temp_root/gateway" -bootstrap "$temp_root/bootstrap" \
  -installation-id "$installation_id" -control-token "$token"
"$temp_root/control" binding add --state "$state_root" --bootstrap "$temp_root/bootstrap" \
  | assert_json 'value["ok"] and value["installation_id"] == "'"$installation_id"'"' 'binding add registers a gateway'
"$temp_root/control" binding list --state "$state_root" \
  | assert_json 'len(value) == 1 and value[0]["installation_id"] == "'"$installation_id"'"' 'binding list shows the gateway'
control_port=$(printf '%s' "$init_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["listen_address"].rsplit(":",1)[1])')
"$temp_root/control" serve --state "$state_root" &
control_pid=$!
wait_port "$control_port" open control

status=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  --data '{"action":"list"}' "http://127.0.0.1:$control_port/__local_remote_control")
[[ "$status" == 401 ]] || fail 'control rejects a missing token'
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
  "http://127.0.0.1:$control_port/__local_remote_control")
[[ "$status" == 405 ]] || fail 'control only permits POST'
status=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
  -H 'Content-Type: application/json' --data '{' "http://127.0.0.1:$control_port/__local_remote_control")
[[ "$status" == 400 ]] || fail 'control rejects malformed JSON'
control '{"action":"list"}' | assert_json 'value["ok"] and value.get("apps", []) == []' 'empty registry has no default app'
control '{"action":"destroy","id":"x"}' | assert_json 'value["code"] == "command_not_allowed"' 'unknown action is denied'
curl -sS "http://127.0.0.1:$control_port/" | grep -q '尚未选择远程应用' || fail 'proxy has no implicit application'

definition="$temp_root/fixture.json"
python3 - "$definition" "$harness_dir/fixture_server.py" "$app_port" <<'PY'
import json
import sys
value = {
    "id": "fixture", "name": "Fixture", "description": "", "icon": "F", "accent": "#2563eb",
    "proxy_url": f"http://127.0.0.1:{sys.argv[3]}",
    "command": sys.executable, "arguments": [sys.argv[2], sys.argv[3]], "stop_command": "",
    "stop_arguments": [], "workdir": ""
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(value))
PY
"$temp_root/control" app set --state "$state_root" --file "$definition" | assert_json 'value["ok"] and value["changed"]' 'app set atomically adds application'
"$temp_root/control" app set --state "$state_root" --file "$definition" | assert_json 'value["ok"] and not value["changed"]' 'app set is idempotent'
invalid_definition="$temp_root/invalid.json"
printf '%s\n' '{"id":"fixture","unexpected":true}' > "$invalid_definition"
if "$temp_root/control" app set --state "$state_root" --file "$invalid_definition" >/dev/null 2>&1; then
  fail 'app set accepts an invalid definition'
fi
"$temp_root/control" app list --state "$state_root" | assert_json 'len(value["apps"]) == 1 and value["apps"][0]["name"] == "Fixture"' 'invalid app set preserves registry'
control '{"action":"list"}' | assert_json 'len(value["apps"]) == 1 and value["apps"][0]["code"] == "stopped"' 'disabled application reports stopped'
status=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Cookie: RemoteEverythingApp=fixture' "http://127.0.0.1:$control_port/test")
[[ "$status" == 502 ]] || fail 'selected stopped application returns gateway error'

control '{"action":"start","id":"fixture"}' | assert_json 'value["ok"] and value["enabled"]' 'start enables application'
wait_port "$app_port" open fixture-start
control '{"action":"status","id":"fixture"}' | assert_json 'value["running"] and value["code"] == "ready"' 'status becomes ready'
curl -sS -H 'Cookie: RemoteEverythingApp=fixture; KeepMe=yes' \
  "http://127.0.0.1:$control_port/deep?q=1" | assert_json 'value["path"] == "/deep?q=1" and value["cookie"] == "KeepMe=yes"' 'proxy semantics are stable'
control '{"action":"status","id":"missing"}' | assert_json 'not value["ok"] and value["code"] == "app_not_found"' 'unknown application error is stable'
control '{"action":"stop","id":"fixture"}' | assert_json 'value["ok"] and not value["enabled"]' 'stop disables application'
wait_port "$app_port" closed fixture-stop

tree_port=$(free_port)
tree_pid_file="$temp_root/tree.pid"
python3 - "$definition" "$harness_dir/fixture_server.py" "$tree_port" "$tree_pid_file" <<'PY'
import json
import sys
value = {
    "id": "tree", "name": "Tree", "description": "", "icon": "T", "accent": "#2563eb",
    "proxy_url": f"http://127.0.0.1:{sys.argv[3]}", "command": sys.executable,
    "arguments": [sys.argv[2], "--launch-child", sys.argv[3], sys.argv[4]],
    "stop_command": "", "stop_arguments": [], "workdir": ""
}
open(sys.argv[1], "w", encoding="utf-8").write(json.dumps(value))
PY
"$temp_root/control" app set --state "$state_root" --file "$definition" >/dev/null
control '{"action":"start","id":"tree"}' >/dev/null
for _ in {1..100}; do [[ -s "$tree_pid_file" ]] && break; sleep 0.05; done
[[ -s "$tree_pid_file" ]] || fail 'launcher did not record descendant pid'
control '{"action":"stop","id":"tree"}' >/dev/null
tree_pid=$(cat "$tree_pid_file")
if kill -0 "$tree_pid" 2>/dev/null; then fail 'launcher descendant survived direct parent exit'; fi
wait_port "$tree_port" closed tree-stop
"$temp_root/control" app remove --state "$state_root" tree >/dev/null

control '{"action":"start","id":"fixture"}' >/dev/null
wait_port "$app_port" open fixture-restart
kill -KILL "$control_pid"
wait "$control_pid" 2>/dev/null || true
control_pid=
wait_port "$app_port" closed parent-exit

"$temp_root/control" app remove --state "$state_root" fixture | assert_json 'value["ok"] and value["changed"]' 'app remove deletes application'
"$temp_root/control" app remove --state "$state_root" fixture | assert_json 'value["ok"] and not value["changed"]' 'app remove is idempotent'

printf '{"ok":true,"suite":"%s-node","semantics":21}\n' "$suite"
