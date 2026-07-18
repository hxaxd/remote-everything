#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${PUBLIC_HOST:?set PUBLIC_HOST to the public IP or DNS name}"
: "${WINDOWS_USER:?set WINDOWS_USER to the Windows account name}"
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "invalid PUBLIC_HOST" >&2; exit 1; }
[[ "$WINDOWS_USER" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid WINDOWS_USER" >&2; exit 1; }

frp_version=0.70.0

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

if ! id kimi-control >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kimi-control --shell /usr/sbin/nologin kimi-control
fi
if ! id kimi-enroll >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kimi-enrollment --shell /usr/sbin/nologin kimi-enroll
fi
if ! id kimi-frp >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/kimi-frp --shell /usr/sbin/nologin kimi-frp
fi
passwd -l kimi-control >/dev/null 2>&1 || true
passwd -l kimi-enroll >/dev/null 2>&1 || true
passwd -l kimi-frp >/dev/null 2>&1 || true
# SSH 隧道时代遗留：kimi-tunnel 用户与家目录整体退役
if id kimi-tunnel >/dev/null 2>&1; then
  userdel kimi-tunnel 2>/dev/null || true
fi
rm -rf /var/lib/kimi-tunnel /var/lib/kimi-control/.ssh

install -d -m 755 /etc/kimi-gateway
install -d -m 755 /etc/kimi-gateway/approved-clients
install -d -m 700 -o kimi-enroll -g kimi-enroll /var/lib/kimi-enrollment/requests
rmdir /opt/kimi-gateway 2>/dev/null || true

if [ ! -s /etc/kimi-gateway/control-token ]; then
  openssl rand -hex 32 > /etc/kimi-gateway/control-token
  chmod 640 /etc/kimi-gateway/control-token
  chown root:kimi-control /etc/kimi-gateway/control-token
fi
if [ ! -s /etc/kimi-gateway/frp-token ]; then
  openssl rand -hex 32 > /etc/kimi-gateway/frp-token
fi
chmod 640 /etc/kimi-gateway/frp-token
chown root:kimi-frp /etc/kimi-gateway/frp-token
if [ ! -s /etc/kimi-gateway/bootstrap-client.p12 ]; then
  TARGET_DIR=/etc/kimi-gateway "$script_dir/generate_bootstrap.sh" >/dev/null
fi
"$script_dir/generate_device_issuer.sh" >/dev/null

# SSH 隧道时代遗留密钥与配置全部清除
rm -f /etc/kimi-gateway/tunnel-client.key /etc/kimi-gateway/tunnel-client.key.pub \
      /etc/ssh/sshd_config.d/90-kimi-tunnel.conf /usr/local/sbin/agent-remote-register-windows-host

printf '{"windows_user":"%s"}\n' "$WINDOWS_USER" > /etc/kimi-gateway/config.json
chmod 644 /etc/kimi-gateway/config.json
cp /etc/kimi-gateway/bootstrap-ca.crt.pem /etc/kimi-gateway/client-trust.pem
for certificate in /etc/kimi-gateway/approved-clients/*.pem; do
  [ -f "$certificate" ] && cat "$certificate" >> /etc/kimi-gateway/client-trust.pem
done
chmod 644 /etc/kimi-gateway/client-trust.pem

if ! /usr/local/sbin/frps --version 2>/dev/null | grep -qF "$frp_version"; then
  curl -1sLf --retry 3 --retry-delay 2 \
    "https://github.com/fatedier/frp/releases/download/v${frp_version}/frp_${frp_version}_linux_amd64.tar.gz" \
    -o /tmp/agent-remote-frp.tar.gz
  tar -xzf /tmp/agent-remote-frp.tar.gz -C /tmp
  install -m 755 "/tmp/frp_${frp_version}_linux_amd64/frps" /usr/local/sbin/frps
  rm -rf /tmp/agent-remote-frp.tar.gz "/tmp/frp_${frp_version}_linux_amd64"
fi

install -m 755 "$script_dir/gateway/agent-remote-gateway" /usr/local/sbin/agent-remote-gateway
printf '#!/bin/sh\nexec /usr/local/sbin/agent-remote-gateway enroll "$@"\n' > /usr/local/sbin/agent-remote-enroll
chmod 755 /usr/local/sbin/agent-remote-enroll
rm -f /opt/kimi-gateway/status_server.py /opt/kimi-gateway/enrollment_server.py /usr/local/sbin/kimi-enroll

frp_token=$(cat /etc/kimi-gateway/frp-token)
sed -e "s/__FRP_TOKEN__/$frp_token/g" "$script_dir/frps.toml" > /etc/kimi-gateway/frps.toml
chown root:kimi-frp /etc/kimi-gateway/frps.toml
chmod 640 /etc/kimi-gateway/frps.toml

install -m 644 "$script_dir/frps.service" /etc/systemd/system/frps.service
install -m 644 "$script_dir/kimi-gateway-status.service" /etc/systemd/system/kimi-gateway-status.service
install -m 644 "$script_dir/kimi-enrollment.service" /etc/systemd/system/kimi-enrollment.service

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
systemctl enable --now kimi-gateway-status.service kimi-enrollment.service frps.service caddy
systemctl reload caddy

bundle=/root/agent-remote-bundle
install -d -m 700 "$bundle"
install -m 600 /etc/kimi-gateway/bootstrap-client.p12 "$bundle/bootstrap-client.p12"
# PC 隧道客户端证书（bootstrap CA 签发；Go 系 TLS 客户端只按 CA 链出示证书，故不用 device-issuer）
if [ ! -s "$bundle/pc-wss.crt.pem" ]; then
  build=$(mktemp -d)
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$build/pc.key.pem" >/dev/null 2>&1
  openssl req -new -key "$build/pc.key.pem" -subj '/CN=Agent Remote Windows Host' -out "$build/pc.csr.pem"
  printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' 'extendedKeyUsage=clientAuth' > "$build/pc.ext"
  openssl x509 -req -in "$build/pc.csr.pem" -CA /etc/kimi-gateway/bootstrap-ca.crt.pem -CAkey /etc/kimi-gateway/bootstrap-ca.key.pem -CAcreateserial -sha256 -days 3650 -extfile "$build/pc.ext" -out "$build/pc.crt.pem" >/dev/null 2>&1
  cat "$build/pc.crt.pem" /etc/kimi-gateway/bootstrap-ca.crt.pem > "$bundle/pc-wss.crt.pem"
  install -m 600 "$build/pc.key.pem" "$bundle/pc-wss.key.pem"
  chmod 644 "$bundle/pc-wss.crt.pem"
  rm -rf "$build"
fi
control_token=$(cat /etc/kimi-gateway/control-token)
bootstrap_password=$(cat /etc/kimi-gateway/bootstrap-password)
printf '{"public_host":"%s","windows_user":"%s","control_token":"%s","frp_token":"%s","bootstrap_password":"%s","bootstrap_fingerprint":"%s"}\n' \
  "$PUBLIC_HOST" "$WINDOWS_USER" "$control_token" "$frp_token" "$bootstrap_password" "$bootstrap_fingerprint" \
  > "$bundle/config.json"
chmod 600 "$bundle/config.json"

systemctl --no-pager --full is-active ssh caddy kimi-gateway-status kimi-enrollment frps
ss -lnt | grep -E ':(22|443|7000|58629|58631)[[:space:]]'
printf 'bundle=%s\n' "$bundle"
