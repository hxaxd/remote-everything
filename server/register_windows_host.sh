#!/bin/sh
set -eu

input=${1:?windows host public key file required}
read -r key_type key_data _rest < "$input"
case "$key_type" in
  ssh-ed25519|ecdsa-sha2-nistp256) ;;
  *) echo "unsupported host key type" >&2; exit 1 ;;
esac
case "$key_data" in
  *[!A-Za-z0-9+/=]*|'') echo "invalid host key" >&2; exit 1 ;;
esac

target=/var/lib/kimi-control/.ssh/known_hosts
temporary=$(mktemp)
trap 'rm -f "$temporary"' EXIT
printf '[127.0.0.1]:58630 %s %s\n' "$key_type" "$key_data" > "$temporary"
install -o kimi-control -g kimi-control -m 600 "$temporary" "$target"
echo "registered Windows host key"
