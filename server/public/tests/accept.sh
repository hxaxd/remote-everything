#!/usr/bin/env bash
# The public shape, deployed: one host running two nodes, the gateway, frps, two
# frpc agents and the 443 entrance, driven end to end by curl and openssl.
#
# This is the shape no Go test reaches. The 443 entrance is the only thing that
# verifies a device certificate and tells the gateway which device a request came
# from, so what the shared behaviour suite assumes about it — that a verified
# certificate, and nothing a client says, is what speaks for a device — is checked
# here against the deployment's real components rather than a stand-in for them.
# Two nodes are deployed rather than one because that is what the protocol is
# about: a request names the node it is for, and a device reaches the ones it was
# granted. Two tunnels through one frps and one gateway, with one node taken down
# while the other keeps answering, is the only way to see that from outside.
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
#
# What the deployment renders is the deployment's own templates, unchanged: there
# is one frps, one Caddyfile, and one frpc per node. The 443 entrance's
# configuration names nothing about a node at all, which is why adding one does
# not touch it.
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
# The two machines this deployment serves, and the names their operator gave them.
# They are two node processes on one host rather than two hosts, so each listens on
# an address of its own: a deployment gives each machine its own, and two nodes that
# shared one would answer for each other.
node_names=(Workshop Attic)
node_hosts=(127.0.0.1 127.0.0.2)
node_ids=()
node_listens=()
tunnel_ports=()
node_pids=()

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
# A node's own control endpoint, reached the way the gateway reaches it: through
# the tunnel that node's agent holds open, with that node's own token. Which token
# is accepted is what makes the gateway's view of a node real rather than assumed.
tunnel_answers() { # tunnel_answers BUNDLE_DIRECTORY TUNNEL_PORT
  local token
  token=$(cat "$1/control-token")
  [[ $(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' --data '{"action":"list"}' \
    "http://127.0.0.1:$2/__local_remote_control" 2>/dev/null) == 200 ]]
}
code_with() { # code_with METHOD CERT KEY URL [HEADER]
  local method=$1 certificate=$2 key=$3 url=$4 header=${5:-}
  local -a args=(--silent --show-error --max-time 10 -X "$method" -o "$work/body" -w '%{http_code}')
  [[ -n "$certificate" ]] && args+=(--cert "$certificate" --key "$key")
  [[ -n "$header" ]] && args+=(-H "$header")
  curl "${args[@]}" "$url" 2>/dev/null || true
}
# What the deployment answers for one node: the header is the whole of how a
# request says which machine it is for.
for_node() { echo "X-Remote-Everything-Node: $1"; }

for tool in python3 curl openssl ss; do
  command -v "$tool" >/dev/null || fail "$tool is required"
done
mkdir -p "$work/bin" "$work/logs"
for component in node gateway frps frpc caddy; do
  [[ -f "$materials/$component" ]] || fail "the materials directory has no $component"
  cp "$materials/$component" "$work/bin/"
done
chmod +x "$work/bin/"*

step "two machines record their identities"
for index in 0 1; do
  state="$work/state/node-$index"
  "$work/bin/node" init --state "$state" --listen "${node_hosts[$index]}" >"$work/node-init-$index.json"
  node_ids+=("$(field "$work/node-init-$index.json" node_id)")
  node_listens+=("$(field "$work/node-init-$index.json" listen_address)")
  echo "node ${node_names[$index]} is ${node_ids[$index]} listening on ${node_listens[$index]}"
done
[[ "${node_listens[0]}" != "${node_listens[1]}" ]] || fail "both nodes listen on one address"
[[ "${node_ids[0]}" != "${node_ids[1]}" ]] || fail "both nodes carry one identity"

step "the gateway creates its identity"
"$work/bin/gateway" init --state "$work/state/gateway" --origin "https://$public_host" >"$work/gateway-init.json"
installation_id=$(field "$work/gateway-init.json" installation_id)
pairing_port=$(port_of "$(field "$work/gateway-init.json" pairing_listen)")
status_port=$(port_of "$(field "$work/gateway-init.json" status_listen)")
frps_port=$(port_of "$(field "$work/gateway-init.json" frps_listen)")
for handed_over in frps-token tunnel-ca.crt.pem tunnel-ca.key.pem; do
  [[ -f "$work/state/gateway/$handed_over" ]] || fail "the gateway root is missing $handed_over"
done
echo "origin https://$public_host; pairing $pairing_port; status $status_port; frps $frps_port"

step "each node is added to the gateway and handed its own identity"
for index in 0 1; do
  "$work/bin/gateway" node add --state "$work/state/gateway" --name "${node_names[$index]}" \
    --node-id "${node_ids[$index]}" --node-bootstrap "$work/bootstrap-$index" >"$work/node-add-$index.json"
  tunnel_ports+=("$(port_of "$(field "$work/node-add-$index.json" node_address)")")
  for handed_over in bootstrap.json control-token frpc/frps-token frpc/tunnel-client.crt.pem frpc/tunnel-client.key.pem; do
    [[ -f "$work/bootstrap-$index/$handed_over" ]] || fail "node ${node_names[$index]}'s bundle is missing $handed_over"
  done
  echo "node ${node_names[$index]} is reached on 127.0.0.1:${tunnel_ports[$index]}"
done
[[ "${tunnel_ports[0]}" != "${tunnel_ports[1]}" ]] || fail "both nodes were given one tunnel port"
# Each node holds the token its own bundle carried, and not the other's: a machine
# that leaks what it was given does not hand over the machines beside it.
[[ "$(cat "$work/bootstrap-0/control-token")" != "$(cat "$work/bootstrap-1/control-token")" ]] || fail "two nodes share one control token"
# What the gateway recorded is what the CLI reports: an operator adds devices to
# the nodes it lists.
"$work/bin/gateway" node list --state "$work/state/gateway" | python3 -c "
import json, sys
listed = json.load(sys.stdin)
assert [node['name'] for node in listed] == [$(printf '"%s",' "${node_names[@]}")], listed
assert [node['id'] for node in listed] == [$(printf '"%s",' "${node_ids[@]}")], listed
print(json.dumps(listed, ensure_ascii=False))
"

step "each node imports the identity the gateway handed it"
for index in 0 1; do
  "$work/bin/node" binding add --state "$work/state/node-$index" --bootstrap "$work/bootstrap-$index" >/dev/null
done

step "the deployment's own templates are rendered"
cat >"$work/frps-input.json" <<EOF
{"frps_port": $frps_port, "frps_token_file": "$(field "$work/gateway-init.json" frps_token_file)", "frps_log": "$work/logs/frps.log"}
EOF
python3 "$render" frps --input "$work/frps-input.json" --output "$work/frps.toml"
for index in 0 1; do
  cat >"$work/frpc-input-$index.json" <<EOF
{"public_host": "$public_host",
 "tunnel_client_cert": "$work/bootstrap-$index/frpc/tunnel-client.crt.pem",
 "tunnel_client_key": "$work/bootstrap-$index/frpc/tunnel-client.key.pem",
 "frps_token_file": "$work/bootstrap-$index/frpc/frps-token",
 "frpc_log": "$work/logs/frpc-$index.log",
 "node_id": "${node_ids[$index]}",
 "node_host": "${node_listens[$index]%:*}", "node_port": $(port_of "${node_listens[$index]}"),
 "node_tunnel_port": ${tunnel_ports[$index]}}
EOF
  python3 "$render" frpc --input "$work/frpc-input-$index.json" --output "$work/frpc-$index.toml"
done
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
echo "rendered one frps.toml, two frpc.toml and one Caddyfile from the deployment's templates"

step "the deployment's components start"
XDG_DATA_HOME="$work/caddy-data" XDG_CONFIG_HOME="$work/caddy-config" \
  "$work/bin/caddy" run --config "$work/Caddyfile" --adapter caddyfile >"$work/logs/caddy.log" 2>&1 &
pids+=($!)
"$work/bin/frps" -c "$work/frps.toml" >"$work/logs/frps-stdio.log" 2>&1 &
pids+=($!)
"$work/bin/gateway" serve --state "$work/state/gateway" >"$work/logs/gateway.log" 2>&1 &
pids+=($!)
for index in 0 1; do
  "$work/bin/node" serve --state "$work/state/node-$index" >"$work/logs/node-$index.log" 2>&1 &
  pids+=($!)
  node_pids+=($!)
done

step "the entrance answers on 443"
wait_for "the 443 entrance" answering
root_ca="$work/caddy-data/caddy/pki/authorities/local/root.crt"
wait_for "the entrance's own authority" test -s "$root_ca"
cp "$root_ca" "$ca_store/$ca_alias.crt"
update-ca-certificates >/dev/null 2>&1
echo "an unauthenticated request is answered with $(code_with GET "" "" "https://$public_host/__remote_everything/apps")"

step "a client is counted as itself, not as the entrance in front of the gateway"
# The gateway sees every device arrive from the entrance, which is why what it
# counts a request against has to be the client that entrance named: counting the
# peer would put every device in the deployment in one bucket. The pairing endpoint
# is the one a client can reach without a credential, so it is asked from two real
# sources: 127.0.0.2 spends the per-client limit, and 127.0.0.3 keeps its own.
attempt() { # attempt SOURCE -> status of one pairing attempt from that source
  curl -sS -o /dev/null -w '%{http_code}' --max-time 10 --interface "$1" -X POST     -H "Authorization: Invitation $bogus_invitation" -H 'Content-Type: application/json'     --data "$pair_body" "https://$public_host/__remote_everything_pair" 2>/dev/null || true
}
bogus_invitation=$(python3 -c "print('z' * 43)")
# The password is never checked, the invitation above is bogus, but a literal one
# here reads as a committed credential, so it is generated.
bogus_password=$(python3 -c "import secrets; print(secrets.token_hex(16))")
pair_body=$(python3 -c "import json, sys; print(json.dumps({'device_name': 'Limits', 'credential_password': sys.argv[1]}))" "$bogus_password")
exhausted=""
for _ in $(seq 1 12); do
  exhausted=$(attempt 127.0.0.2)
  [[ "$exhausted" == 429 ]] && break
done
[[ "$exhausted" == 429 ]] || fail "one client spent 12 pairing attempts without hitting its limit (last answer $exhausted)"
fresh=$(attempt 127.0.0.3)
[[ "$fresh" != 429 ]] || fail "a second client was rate-limited by the first one's requests"
echo "the client that spent its limit is answered $exhausted, and another client is answered $fresh"

step "the tunnel brings each node's control port to the gateway"
for index in 0 1; do
  "$work/bin/frpc" -c "$work/frpc-$index.toml" >"$work/logs/frpc-stdio-$index.log" 2>&1 &
  pids+=($!)
done
for index in 0 1; do
  wait_for "node ${node_names[$index]}'s tunnel listener" listening "${tunnel_ports[$index]}"
  wait_for "node ${node_names[$index]} to answer through the tunnel" tunnel_answers "$work/bootstrap-$index" "${tunnel_ports[$index]}"
  # The other node's port is not this node: both tunnels go through one frps, and
  # each one only accepts the token its own bundle carried.
  other=$((1-index))
  token=$(cat "$work/bootstrap-$index/control-token")
  [[ $(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' --data '{"action":"list"}' \
    "http://127.0.0.1:${tunnel_ports[$other]}/__local_remote_control" 2>/dev/null) == 200 ]] \
    && fail "one node's token opened another node's tunnel"
  echo "node ${node_names[$index]} answers on 127.0.0.1:${tunnel_ports[$index]} through frps and its own frpc"
done

step "a node's tunnel port is published on loopback only"
command -v ss >/dev/null || fail "ss (iproute2) is needed to see where a tunnel port is published"
for index in 0 1; do
  bound=$(ss -ltn "sport = :${tunnel_ports[$index]}" | tail -n +2 | awk '{print $4; exit}')
  [[ -n "$bound" ]] || fail "node ${node_names[$index]}'s tunnel port is not published"
  [[ "$bound" == 127.0.0.1:* ]] || fail "node ${node_names[$index]}'s tunnel port is on $bound, which anything reaching this machine can dial"
  echo "node ${node_names[$index]}'s control plane is published on $bound"
done

step "an invitation is issued for one node"
"$work/bin/gateway" device --state "$work/state/gateway" invite --name "Acceptance Phone" \
  --node "${node_names[0]}" --ttl 10m >"$work/invite.json"
invitation=$(field "$work/invite.json" invitation)
python3 - "$work/invite.json" "$public_host" "${node_ids[0]}" "${node_names[0]}" <<'PY'
import json, sys, urllib.parse
issued = json.load(open(sys.argv[1], encoding="utf-8"))
uri = urllib.parse.urlparse(issued["setup_uri"])
carried = urllib.parse.parse_qs(uri.query)
assert uri.scheme == "remote-everything" and uri.netloc == "setup", issued["setup_uri"]
assert carried["origin"] == ["https://" + sys.argv[2]], carried.get("origin")
assert carried["node"] == [sys.argv[3]], carried.get("node")
assert carried["node_name"] == [sys.argv[4]], carried.get("node_name")
# An invitation describes one node on one gateway: what a client reads is that
# description, not a version or a shape.
assert sorted(carried) == ["invitation", "node", "node_name", "origin"], sorted(carried)
assert issued["node_id"] == sys.argv[3] and issued["node_name"] == sys.argv[4], issued
print("the setup URI carries the node it opens, its name, the origin and the invitation")
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
header=$(for_node "${node_ids[0]}")
[[ $(code_with POST "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything_activate" "$header") == 202 ]] \
  || fail "activation was not left waiting for the operator"
"$work/bin/gateway" device --state "$work/state/gateway" approve "$fingerprint" | json 'value["ok"]' 'the operator could not approve the device'
status=$(code_with POST "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything_activate" "$header")
[[ "$status" == 200 ]] || fail "the approved device was answered with $status"
json 'value["ok"] and value["computer_connected"]' 'the activated device did not reach the node' <"$work/body"
echo "activation reached the node through the tunnel and the menu answered"

step "a request says which node it is for"
[[ $(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps") == 401 ]] \
  || fail "a request that named no node was answered"
echo "a request that names no node is answered with 401"
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[1]}")")
[[ "$status" == 401 ]] || fail "a device reached a node it was not granted: $status"
echo "the node the invitation did not open is refused with 401"
"$work/bin/gateway" device --state "$work/state/gateway" list | python3 -c "
import json, sys
devices = json.load(sys.stdin)
assert len(devices) == 1, devices
assert devices[0]['nodes'] == ['${node_ids[0]}'], devices
print(json.dumps({'device_name': devices[0]['device_name'], 'nodes': devices[0]['nodes']}, ensure_ascii=False))
"

step "the device asks which nodes it may reach"
curl -sS --max-time 10 --cert "$work/device.crt.pem" --key "$work/device.key.pem" \
  "https://$public_host/__remote_everything/nodes" -o "$work/nodes.json"
python3 -c "
import json
listed = json.load(open('$work/nodes.json'))
assert listed['ok'], listed
assert [node['name'] for node in listed['nodes']] == ['${node_names[0]}'], listed
print(json.dumps(listed, ensure_ascii=False))
"

step "a node granted to a device is reachable without pairing again"
"$work/bin/gateway" device --state "$work/state/gateway" grant --node "${node_names[1]}" "$fingerprint" | json 'value["ok"] and value["changed"]' 'the second node could not be granted'
curl -sS --max-time 10 --cert "$work/device.crt.pem" --key "$work/device.key.pem" \
  "https://$public_host/__remote_everything/nodes" -o "$work/nodes.json"
python3 -c "
import json
listed = json.load(open('$work/nodes.json'))
assert [node['name'] for node in listed['nodes']] == [$(printf '"%s",' "${node_names[@]}")], listed
" || fail "the granted node is not what the device may reach"
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[1]}")")
[[ "$status" == 200 ]] || fail "a granted node was answered with $status"
json 'value["ok"] and value["computer_connected"]' 'the granted node did not answer' <"$work/body"
echo "the granted node answers, and only the granted one is listed"

step "the admitted device reaches an application page"
[[ $(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/editor/" "$(for_node "${node_ids[0]}")") == 200 ]] \
  || fail "the page a device opened was not served"
grep -q '尚未选择远程应用' "$work/body" || fail 'the page did not come from the node'
echo "page traffic is served to the admitted device"

step "one node going down does not take the other with it"
kill -KILL "${node_pids[1]}" 2>/dev/null || fail "the second node could not be stopped"
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[1]}")")
[[ "$status" == 200 ]] || fail "the stopped node was answered with $status"
json 'not value["computer_connected"] and value["code"] == "computer_offline"' 'the stopped node did not report itself offline' <"$work/body"
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[0]}")")
[[ "$status" == 200 ]] || fail "the node that stayed up was answered with $status"
json 'value["computer_connected"]' 'the node that stayed up stopped answering' <"$work/body"
echo "each node answers for itself: one tunnel down leaves the other reachable"

step "the entrance is the only thing that speaks for a client"
# A device that could name itself would be a device that could be anyone. What
# prevents that is the entrance overwriting the fingerprint header with the one it
# verified, so a client's own claim never arrives: this request claims a device
# that does not exist and is served as the device its certificate belongs to.
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" \
  "X-Remote-Everything-Client-Fingerprint: $(printf 'ab%.0s' {1..32})")
[[ "$status" == 401 ]] || fail "a claimed fingerprint was believed: $status"
status=$(code_with GET "$work/device.crt.pem" "$work/device.key.pem" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[0]}")")
[[ "$status" == 200 ]] || fail "a claim displaced the certificate the entrance verified: $status"
status=$(code_with GET "" "" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[0]}")")
[[ "$status" == 401 ]] || fail "a client with no credential was answered with $status"
echo "a claim is ignored: only the certificate the entrance verified speaks for a device"

step "a certificate this deployment never issued is not a credential"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout "$work/stranger.key.pem" \
  -out "$work/stranger.crt.pem" -days 1 -nodes -subj "//CN=Acceptance Phone" 2>/dev/null
status=$(code_with GET "$work/stranger.crt.pem" "$work/stranger.key.pem" "https://$public_host/__remote_everything/apps" "$(for_node "${node_ids[0]}")")
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
assert sorted(devices[0]['nodes']) == sorted(['${node_ids[0]}', '${node_ids[1]}']), devices
print(json.dumps({k: devices[0][k] for k in ('device_name', 'status', 'approved_at', 'activated_at')}, ensure_ascii=False))
"

printf '{"ok":true,"suite":"public-deployment","semantics":20}\n'
