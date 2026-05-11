#!/bin/bash
# In-distro bootstrap. Runs as root inside a freshly-imported Debian rootfs.
# Idempotent: re-runs cleanly.
set -euo pipefail

mkdir -p /var/lib/claudearium

export DEBIAN_FRONTEND=noninteractive

echo "[bootstrap] apt-get update"
apt-get update -qq

echo "[bootstrap] installing base packages"
apt-get install -y -qq --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    git \
    jq \
    unzip \
    sudo \
    nftables \
    wireguard-tools \
    systemd \
    iproute2 \
    locales \
    less

echo "[bootstrap] locale"
sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true

echo "[bootstrap] creating passwordless 'claude' user"
if ! id -u claude >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo claude
fi
# Delete any password and unlock the account.
passwd -d claude >/dev/null 2>&1 || true
usermod -U claude >/dev/null 2>&1 || true

echo "[bootstrap] passwordless sudo for 'claude'"
install -m 0440 /dev/null /etc/sudoers.d/claude
cat >/etc/sudoers.d/claude <<'EOF'
claude ALL=(ALL) NOPASSWD: ALL
Defaults:claude !env_reset, !secure_path
EOF
chmod 0440 /etc/sudoers.d/claude
visudo -cf /etc/sudoers.d/claude >/dev/null

echo "[bootstrap] WSL Windows-interop binfmt registration (oneshot at boot)"
cat >/etc/systemd/system/claudearium-wsl-interop.service <<'EOF'
[Unit]
Description=Register WSL Windows Interop binfmt
DefaultDependencies=no
After=systemd-binfmt.service
ConditionPathExists=/proc/sys/fs/binfmt_misc/register

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'test -e /proc/sys/fs/binfmt_misc/WSLInterop || echo ":WSLInterop:M::MZ::/init:PF" > /proc/sys/fs/binfmt_misc/register'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable claudearium-wsl-interop.service >/dev/null 2>&1 || true

echo "[bootstrap] marking provisioned"
date -Iseconds > /var/lib/claudearium/provisioned

echo "[bootstrap] done"
