#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/cloud-init-teleport.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

# ── Wait for apt lock ──────────────────────────────────────────────────────
systemctl disable --now unattended-upgrades || true
systemctl disable --now apt-daily.timer || true
systemctl disable --now apt-daily-upgrade.timer || true

systemd-run --property="After=apt-daily.service apt-daily-upgrade.service" \
  --wait /bin/true 2>/dev/null || true

while fuser /var/lib/dpkg/lock-frontend \
            /var/lib/apt/lists/lock \
            /var/lib/dpkg/lock \
            /var/cache/apt/archives/lock >/dev/null 2>&1; do
  echo "Waiting for apt lock..."
  sleep 5
done

dpkg --configure -a || true
sleep 5

apt_install() {
  for i in 1 2 3 4 5; do
    apt-get "$@" && return 0
    echo "apt-get failed (attempt $i), retrying in 15s..."
    sleep 15
  done
  return 1
}

apt_install update
apt_install install -y curl

# ── Install Teleport Enterprise ────────────────────────────────────────────
curl -fsSL https://cdn.teleport.dev/install-v18.7.1.sh | bash -s 18.7.1 enterprise

# ── Write Teleport node config ─────────────────────────────────────────────
cat > /etc/teleport.yaml << 'TELEPORT_CFG'
version: v3
teleport:
  nodename: ssh-node-1
  data_dir: /var/lib/teleport
  log:
    output: stderr
    severity: INFO
  join_params:
    method: iam
    token_name: ssh-node-iam-token
  proxy_server: grant-tam-teleport.gvteleport.com:443

auth_service:
  enabled: false

proxy_service:
  enabled: false

ssh_service:
  enabled: true
  labels:
    team: okta-teleport-users
    env: demo
    node: ssh-node-1
  enhanced_recording:
    enabled: true
    command_buffer_size: 8
    disk_buffer_size: 300
    network_buffer_size: 8
    cgroup_path: /cgroup2
  commands:
    - name: hostname
      command: [hostname]
      period: 1m0s
TELEPORT_CFG

# ── Mount cgroupv2 for BPF enhanced session recording ─────────────────────
mkdir -p /cgroup2
mount -t cgroup2 none /cgroup2 || true

# Add persistent mount to fstab if not already present
grep -q '/cgroup2' /etc/fstab || echo 'none /cgroup2 cgroup2 defaults 0 0' >> /etc/fstab

# Re-exec systemd so it picks up the new cgroup2 mount before Teleport starts.
# Without this, systemd fails to create the Teleport service cgroup after the
# new mount is added, causing teleport.service to exit with status=219/CGROUP.
systemctl daemon-reexec

# ── Enable and start Teleport ──────────────────────────────────────────────
# --insecure is required while the proxy uses a Let's Encrypt staging cert.
# Remove this drop-in once acmeURI is switched to production.
mkdir -p /etc/systemd/system/teleport.service.d
cat > /etc/systemd/system/teleport.service.d/insecure.conf << 'DROPIN'
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
DROPIN

systemctl daemon-reload
systemctl enable teleport
systemctl start teleport

echo "ssh-node-1 Teleport agent started — joining via AWS IAM join method"
