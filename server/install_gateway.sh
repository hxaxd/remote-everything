#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${PUBLIC_HOST:?set PUBLIC_HOST to the public IP or DNS name}"
: "${WINDOWS_USER:?set WINDOWS_USER to the Windows account name}"
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "invalid PUBLIC_HOST" >&2; exit 1; }
[[ "$WINDOWS_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid WINDOWS_USER" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apt-transport-https ca-certificates curl debian-archive-keyring debian-keyring gpg openssh-server openssl python3 python3-cryptography

if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  chmod 644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

if ! id kimi-tunnel >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kimi-tunnel --shell /usr/sbin/nologin kimi-tunnel
fi
if ! id kimi-control >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kimi-control --shell /usr/sbin/nologin kimi-control
fi
if ! id kimi-enroll >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kimi-enrollment --shell /usr/sbin/nologin kimi-enroll
fi
passwd -l kimi-tunnel >/dev/null 2>&1 || true
passwd -l kimi-control >/dev/null 2>&1 || true
passwd -l kimi-enroll >/dev/null 2>&1 || true

install -d -m 755 /opt/kimi-gateway /etc/kimi-gateway
install -d -m 755 /etc/kimi-gateway/approved-clients
install -d -m 700 -o kimi-enroll -g kimi-enroll /var/lib/kimi-enrollment/requests
install -d -m 700 -o kimi-tunnel -g kimi-tunnel /var/lib/kimi-tunnel/.ssh
install -d -m 700 -o kimi-control -g kimi-control /var/lib/kimi-control/.ssh

if [ ! -s /etc/kimi-gateway/control-token ]; then
  openssl rand -hex 32 > /etc/kimi-gateway/control-token
  chmod 640 /etc/kimi-gateway/control-token
  chown root:kimi-control /etc/kimi-gateway/control-token
fi
if [ ! -s /etc/kimi-gateway/bootstrap-client.p12 ]; then
  TARGET_DIR=/etc/kimi-gateway "$script_dir/generate_bootstrap.sh" >/dev/null
fi
"$script_dir/generate_device_issuer.sh" >/dev/null

if [ ! -s /etc/kimi-gateway/tunnel-client.key ]; then
  ssh-keygen -q -t ed25519 -N '' -C agent-remote-tunnel -f /etc/kimi-gateway/tunnel-client.key
fi
chmod 600 /etc/kimi-gateway/tunnel-client.key
chmod 644 /etc/kimi-gateway/tunnel-client.key.pub

if [ ! -s /var/lib/kimi-control/.ssh/id_ed25519 ]; then
  ssh-keygen -q -t ed25519 -N '' -C agent-remote-cloud-control -f /var/lib/kimi-control/.ssh/id_ed25519
fi
touch /var/lib/kimi-control/.ssh/known_hosts
chown -R kimi-control:kimi-control /var/lib/kimi-control/.ssh
chmod 700 /var/lib/kimi-control/.ssh
chmod 600 /var/lib/kimi-control/.ssh/id_ed25519 /var/lib/kimi-control/.ssh/known_hosts
chmod 644 /var/lib/kimi-control/.ssh/id_ed25519.pub

tunnel_key=$(cat /etc/kimi-gateway/tunnel-client.key.pub)
printf '%s\n' "$tunnel_key" > /var/lib/kimi-tunnel/.ssh/authorized_keys
chown kimi-tunnel:kimi-tunnel /var/lib/kimi-tunnel/.ssh/authorized_keys
chmod 600 /var/lib/kimi-tunnel/.ssh/authorized_keys

printf '{"windows_user":"%s"}\n' "$WINDOWS_USER" > /etc/kimi-gateway/config.json
chmod 644 /etc/kimi-gateway/config.json
cp /etc/kimi-gateway/bootstrap-ca.crt.pem /etc/kimi-gateway/client-trust.pem
for certificate in /etc/kimi-gateway/approved-clients/*.pem; do
  [ -f "$certificate" ] && cat "$certificate" >> /etc/kimi-gateway/client-trust.pem
done
chmod 644 /etc/kimi-gateway/client-trust.pem

install -m 755 "$script_dir/status_server.py" /opt/kimi-gateway/status_server.py
install -m 755 "$script_dir/enrollment_server.py" /opt/kimi-gateway/enrollment_server.py
install -m 755 "$script_dir/kimi-enroll" /usr/local/sbin/kimi-enroll
install -m 755 "$script_dir/kimi-enroll" /usr/local/sbin/agent-remote-enroll
install -m 755 "$script_dir/register_windows_host.sh" /usr/local/sbin/agent-remote-register-windows-host
install -m 644 "$script_dir/kimi-gateway-status.service" /etc/systemd/system/kimi-gateway-status.service
install -m 644 "$script_dir/kimi-enrollment.service" /etc/systemd/system/kimi-enrollment.service
install -m 644 "$script_dir/90-kimi-tunnel.conf" /etc/ssh/sshd_config.d/90-kimi-tunnel.conf

bootstrap_fingerprint=$(cat /etc/kimi-gateway/bootstrap-fingerprint)
sed \
  -e "s/__PUBLIC_HOST__/$PUBLIC_HOST/g" \
  -e "s/__BOOTSTRAP_FINGERPRINT__/$bootstrap_fingerprint/g" \
  "$script_dir/Caddyfile" > /etc/caddy/Caddyfile
chown root:caddy /etc/caddy/Caddyfile
chmod 644 /etc/caddy/Caddyfile

/usr/sbin/sshd -t
systemctl reload ssh
systemctl daemon-reload
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable --now kimi-gateway-status.service kimi-enrollment.service caddy

bundle=/root/agent-remote-bundle
install -d -m 700 "$bundle"
install -m 600 /etc/kimi-gateway/bootstrap-client.p12 "$bundle/bootstrap-client.p12"
install -m 600 /etc/kimi-gateway/tunnel-client.key "$bundle/tunnel-client.key"
install -m 644 /etc/kimi-gateway/tunnel-client.key.pub "$bundle/tunnel-client.key.pub"
install -m 644 /var/lib/kimi-control/.ssh/id_ed25519.pub "$bundle/cloud-control.pub"
install -m 644 /etc/ssh/ssh_host_ed25519_key.pub "$bundle/server-host.pub"
control_token=$(cat /etc/kimi-gateway/control-token)
bootstrap_password=$(cat /etc/kimi-gateway/bootstrap-password)
printf '{"public_host":"%s","windows_user":"%s","control_token":"%s","bootstrap_password":"%s","bootstrap_fingerprint":"%s"}\n' \
  "$PUBLIC_HOST" "$WINDOWS_USER" "$control_token" "$bootstrap_password" "$bootstrap_fingerprint" \
  > "$bundle/config.json"
chmod 600 "$bundle/config.json"

systemctl --no-pager --full is-active ssh caddy kimi-gateway-status kimi-enrollment
ss -lnt | grep -E ':(22|443|58629|58631)[[:space:]]'
printf 'bundle=%s\n' "$bundle"
