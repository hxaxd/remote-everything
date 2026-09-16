#!/usr/bin/env bash
# The public shape, deployed: one host running the node, the gateway, frps, frpc
# and the 443 entrance, driven end to end by curl and openssl.
#
# This is the shape no Go test reaches. The 443 entrance is the only thing that
# verifies a device certificate and tells the gateway which device a request came
# from, so what the shared behaviour suite assumes about it — that a verified
# certificate, and nothing a client says, is what speaks for a device — is checked
# here against the deployment's real components rather than a stand-in for them:
#
#   device ──https──▶ entrance ──┬─ /__remote_everything_pair ──▶ gateway pairing
#                                ├─ /~!frp ──────────────────▶ frps ◀── frpc ──▶ node
#                                └─ everything else ─────────▶ gateway status
#
# Usage, with the release binaries of this repository plus FRP v0.70.0 and Caddy
# v2.11.4 — the versions a deployment pins — in one directory:
#
#   sudo bash server/public/tests/accept.sh MATERIAL_DIRECTORY
#
# The materials directory must hold `node` (the Linux node), `gateway`, `frps`,
# `frpc` and `caddy`. Everything this runs lives in a temporary directory and is
# removed afterwards, including the trust anchors the entrance installs for its
# own certificate: a host with no public name cannot pass an ACME challenge, so
# the rendered Caddyfile issues from Caddy's own authority for the length of one
# run, and that authority is installed and uninstalled with it.
set -euo pipefail

materials=${1:?usage: accept.sh MATERIAL_DIRECTORY}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
render="$repo/skills/remote-everything-install/scripts/render.py"
public_host=${PUBLIC_HOST:-127.0.0.1}
pair_password=${PAIR_PASSWORD:-acceptance-deployment}
ca_store=/usr/local/share/ca-certificates
ca_alias=remote-everything-accept
work=$(mktemp -d /tmp/accept-public-XXXXXX)
declare -a pids=()
before_store=$(ls "$ca_store" 2>/dev/null | sort || true)

[[ $(id -u) == 0 ]] || { echo "the entrance answers on 443, so this must run as root" >&2; exit 1; }

cleanup() {
  for pid in "${pids[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
  # The entrance installs its authority itself, so removing only what this run
  # added means comparing the store against how it was found.
  local touched=0 name
  for file in "$ca_store"/*; do
    [[ -e "$file" ]] || continue
    name=${file##*/}
    if [[ "$name" == "$ca_alias.crt" ]] || ! printf '%s\n' "$before_store" | grep -qxF "$name"; then
      rm -f "$file"
      touched=1
    fi
  done
  [[ "$touched" == 0 ]] || update-ca-certificates --fresh >/dev/null 2>&1 || true
  if [[ -n "${KEEP_WORK:-}" ]]; then echo "kept $work" >&2; else rm -rf -- "$work"; fi
}
trap cleanup EXIT

fail() { echo "assertion failed: $*" >&2; exit 1; }
step() { printf -- '--- %s\n' "$*"; }
json() { python3 -c "import json,sys; value=json.load(sys.stdin); assert $1" || fail "$2"; }
field() { python3 -c "import json,sys; print(json.load(open('$1'))['$2'])"; }
port_of() { python3 -c "print('$1'.rsplit(':',1)[1])"; }

wait_for() {
  local what=$1; shift
  for _ in $(seq 1 300); do "$@" && return 0; sleep 0.1; done
  fail "$what did not happen"
}
listening() { ss -ltn "sport = :$1" | grep -q LISTEN; }
answering() { [[ $(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 "https://$public_host/" 2>/dev/null) == 401 ]]; }
# The node's own control endpoint, reached the way the gateway reaches it: through
# the tunnel the tunnel agent holds open, which is what makes the gateway's view of
# the node real rather than assumed.
tunnel_answers() {
  local token
  token=$(cat "$work/bootstrap/control-token")
  [[ $(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' --data '{"action":"list"}' \
    "http://127.0.0.1:$node_tunnel_port/__local_remote_control" 2>/dev/null) == 200 ]]
}
code_with() { # code_with METHOD CERT KEY URL [HEADER]
  local method=$1 certificate=$2 key=$3 url=$4 header=${5:-}
  local -a args=(--silent --show-error --max-time 10 -X "$method" -o "$work/body" -w '%{http_code}')
  [[ -n "$certificate" ]] && args+=(--cert "$certificate" --key "$key")
  [[ -n "$header" ]] && args+=(-H "$header")
  curl "${args[@]}" "$url" 2>/dev/null || true
}

for tool in python3 curl openssl ss; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
mkdir -p "$work/bin" "$work/logs"
for component in node gateway frps frpc caddy; do
  [[ -f "$materials/$component" ]] || fail "the materials directory has no $component"
  cp "$materials/$component" "$work/bin/"
done
chmod +x "$work/bin/"*

step "a node records its identity"
"$work/bin/node" init --state "$work/state/node" --listen 127.0.0.1 >"$work/node-init.json"
node_listen=$(field "$work/node-init.json" listen_address)
echo "node listening on $node_listen"

step "the gateway creates its identity and the handover bundle"
"$work/bin/gateway" init --state "$work/state/gateway" --node-bootstrap "$work/bootstrap" \
  --origin "https://$public_host" >"$work/gateway-init.json"
installation_id=$(field "$work/gateway-init.json" installation_id)
pairing_port=$(port_of "$(field "$work/gateway-init.json" pairing_listen)")
status_port=$(port_of "$(field "$work/gateway-init.json" status_listen)")
frps_port=$(port_of "$(field "$work/gateway-init.json" frps_listen)")
node_tunnel_port=$(port_of "$(field "$work/gateway-init.json" node_tunnel_listen)")
for handed_over in bootstrap.json control-token frpc/frps-token frpc/tunnel-client.crt.pem frpc/tunnel-client.key.pem; do
  [[ -f "$work/bootstrap/$handed_over" ]] || fail "the handover bundle is missing $handed_over"
done
echo "origin https://$public_host; pairing $pairing_port; status $status_port; frps $frps_port; node tunnel $node_tunnel_port"

step "the node imports the identity the gateway handed it"
"$work/bin/node" binding add --state "$work/state/node" --bootstrap "$work/bootstrap" >/dev/null

step "the deployment's own templates are rendered"
cat >"$work/frps-input.json" <<EOF
{"frps_port": $frps_port, "frps_token_file": "$(field "$work/gateway-init.json" frps_token_file)", "frps_log": "$work/logs/frps.log"}
EOF
cat >"$work/frpc-input.json" <<EOF
{"public_host": "$public_host",
 "tunnel_client_cert": "$work/bootstrap/frpc/tunnel-client.crt.pem",
 "tunnel_client_key": "$work/bootstrap/frpc/tunnel-client.key.pem",
 "frps_token_file": "$(field "$work/gateway-init.json" frps_token_file)",
 "frpc_log": "$work/logs/frpc.log",
 "installation_id": "$installation_id",
 "node_host": "${node_listen%:*}", "node_port": $(port_of "$node_listen"),
 "node_tunnel_port": $node_tunnel_port}
EOF
cat >"$work/caddy-input.json" <<EOF
{"public_host": "$public_host",
 "device_ca_file": "$(field "$work/gateway-init.json" device_ca_file)",
 "tunnel_ca_file": "$(field "$work/gateway-init.json" tunnel_ca_file)",
 "pairing_upstream": "127.0.0.1:$pairing_port",
 "frps_upstream": "127.0.0.1:$frps_port",
 "status_upstream": "127.0.0.1:$status_port",
 "tunnel_issuer_dn": "$(field "$work/gateway-init.json" tunnel_issuer_dn)",
 "device_issuer_dn": "$(field "$work/gateway-init.json" device_issuer_dn)"}
EOF
mkdir -p "$work/caddy-data" "$work/caddy-config"
python3 "$render" frps --input "$work/frps-input.json" --output "$work/frps.toml"
python3 "$render" frpc --input "$work/frpc-input.json" --output "$work/frpc.toml"
python3 "$render" caddy --input "$work/caddy-input.json" --output "$work/Caddyfile"
# The rendered entrance validates client certificates against the device and tunnel
# authorities, routes the tunnel by path and issuer, and covers the device
# fingerprint header. All of that stays exactly as a deployment has it; only where
# it gets its own certificate differs, because no ACME challenge can be answered
# for a host that is not on the internet.
python3 - "$work/Caddyfile" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
acme = "\t\tissuer acme {\n\t\t\tdisable_http_challenge\n\t\t\tprofile shortlived\n\t\t}\n"
assert acme in text, "the rendered entrance obtains its certificate differently than this script expects"
open(path, "w", encoding="utf-8").write(text.replace(acme, "\t\tissuer internal\n"))
PY
echo "rendered frps.toml, frpc.toml and Caddyfile from the deployment's templates"

step "the deployment's components start"
XDG_DATA_HOME="$work/caddy-data" XDG_CONFIG_HOME="$work/caddy-config" \
  "$work/bin/caddy" run --config "$work/Caddyfile" --adapter caddyfile >"$work/logs/caddy.log" 2>&1 &
pids+=($!)
"$work/bin/frps" -c "$work/frps.toml" >"$work/logs/frps-stdio.log" 2>&1 &
pids+=($!)
"$work/bin/gateway" serve --state "$work/state/gateway" >"$work/logs/gateway.log" 2>&1 &
pids+=($!)
"$work/bin/node" serve --state "$work/state/node" >"$work/logs/node.log" 2>&1 &
pids+=($!)

step "the entrance answers on 443"
wait_for "the 443 entrance" answering
root_ca="$work/caddy-data/caddy/pki/authorities/local/root.crt"
wait_for "the entrance's own authority" test -s "$root_ca"
cp "$root_ca" "$ca_store/$ca_alias.crt"
update-ca-certificates >/dev/null 2>&1
echo "an unauthenticated request is answered with $(code_with GET "" "" "https://$public_host/__remote_everything/apps")"

step "the tunnel brings the node's control port to the gateway"
"$work/bin/frpc" -c "$work/frpc.toml" >"$work/logs/frpc-stdio.log" 2>&1 &
pids+=($!)
wait_for "the node tunnel listener" listening "$node_tunnel_port"
wait_for "the node to answer through the tunnel" tunnel_answers
echo "the node answers on 127.0.0.1:$node_tunnel_port through frps and frpc"

step "an invitation is issued for the origin clients dial"
"$work/bin/gateway" device --state "$work/state/gateway" invite --name "Acceptance Phone" --ttl 10m >"$work/invite.json"
invitation=$(field "$work/invite.json" invitation)
python3 - "$work/invite.json" "$public_host" <<'PY'
import json, sys, urllib.parse
issued = json.load(open(sys.argv[1], encoding="utf-8"))
uri = urllib.parse.urlparse(issued["setup_uri"])
carried = urllib.parse.parse_qs(uri.query)
assert uri.scheme == "remote-everything" and uri.netloc == "setup", issued["setup_uri"]
assert carried["mode"] == ["public"], carried.get("mode")
assert carried["origin"] == ["https://" + sys.argv[2]], carried.get("origin")
assert carried["id"] == [issued["installation_id"]], carried.get("id")
print("the setup URI carries the installation, the origin and the invitation")
PY

step "a device pairs over the entrance with no credential at all"
pair_body=$(python3 -c "import json; print(json.dumps({'device_name': 'Acceptance Phone', 'credential_password': '$pair_password'}))")
status=$(curl -sS -o "$work/pair.json" -w '%{http_code}' --max-time 10 \
  -H "Authorization: Invitation $invitation" -H 'Content-Type: application/json' \
  --data "$pair_body" "https://$public_host/__remote_everything_pair")
[[ "$status" == 200 ]] || fail "pairing answered $status: $(cat "$work/pair.json")"
fingerprint=$(field "$work/pair.json" certificate_fingerprint)
python3 -c "
import base64, json
result = json.load(open('$work/pair.json'))
open('$work/credential.p12','wb').write(base64.b64decode(result['credential_pkcs12']))
"
openssl pkcs12 -in "$work/credential.p12" -passin "pass:$pair_password" -clcerts -nokeys -out "$work/device.crt.pem" 2>/dev/null
openssl pkcs12 -in "$work/credential.p12" -passin "pass:$pair_password" -nocerts -nodes -out "$work/device.key.pem" 2>/dev/null
issued=$(openssl x509 -in "$work/device.crt.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')
[[ "$issued" == "$fingerprint" ]] || fail "the credential is not the one it was issued under"
echo "the credential chains to $(openssl x509 -in "$work/device.crt.pem" -noout -issuer | sed 's/^issuer=//')"

step "the device is only admitted once its operator approves it"
[[ $(code_with POST "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything_activate") == 202 ]] \
  || fail "activation was not left waiting for the operator"
"$work/bin/gateway" device --state "$work/state/gateway" approve "$fingerprint" | json 'value["ok"]' 'the operator could not approve the device'
status=$(code_with POST "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything_activate")
[[ "$status" == 200 ]] || fail "the approved device was answered with $status"
json 'value["ok"] and value["computer_connected"]' 'the activated device did not reach the node' <"$work/body"
echo "activation reached the node through the tunnel and the menu answered"

step "the admitted device reaches an application page"
[[ $(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/editor/") == 200 ]] \
  || fail "the page a device opened was not served"
grep -q '尚未选择远程应用' "$work/body" || fail 'the page did not come from the node'
echo "page traffic is served to the admitted device"

step "the entrance is the only thing that speaks for a client"
# A device that could name itself would be a device that could be anyone. What
# prevents that is the entrance overwriting the fingerprint header with the one it
# verified, so a client's own claim never arrives: this request claims a device
# that does not exist and is served as the device its certificate belongs to.
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" "X-Remote-Everything-Client-Fingerprint: $(printf 'ab%.0s' {1..32})")
[[ "$status" == 200 ]] || fail "a claimed fingerprint was believed instead of the certificate: $status"
status=$(code_with GET "" "" "https://$public_host/__remote_everything/apps")
[[ "$status" == 401 ]] || fail "a client with no credential was answered with $status"
echo "a claim is ignored: only the certificate the entrance verified speaks for a device"

step "a certificate this deployment never issued is not a credential"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout "$work/stranger.key.pem" \
  -out "$work/stranger.crt.pem" -days 1 -nodes -subj "//CN=Acceptance Phone" 2>/dev/null
status=$(code_with GET "$work/stranger.crt.pem" "$work/stranger.key.pem" "https://$public_host/__remote_everything/apps")
[[ "$status" != 200 ]] || fail "a certificate from nowhere was admitted"
[[ "$status" != 000 && -n "$status" ]] || status="refused at the handshake"
echo "a foreign certificate is $status"

step "an invitation admits one device"
status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Invitation $invitation" -H 'Content-Type: application/json' \
  --data "$pair_body" "https://$public_host/__remote_everything_pair" 2>/dev/null || true)
[[ "$status" != 200 ]] || fail "a spent invitation paired another device: $status"
echo "a spent invitation is answered with $status"

step "the gateway's record of the device"
"$work/bin/gateway" device --state "$work/state/gateway" list | python3 -c "
import json, sys
devices = json.load(sys.stdin)
assert len(devices) == 1, devices
assert devices[0]['certificate_fingerprint'] == '$fingerprint', devices
assert devices[0]['status'] == 'approved', devices
print(json.dumps({k: devices[0][k] for k in ('device_name', 'status', 'approved_at', 'activated_at')}, ensure_ascii=False))
"

printf '{"ok":true,"suite":"public-deployment","semantics":14}\n'
