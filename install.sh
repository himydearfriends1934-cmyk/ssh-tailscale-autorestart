#!/usr/bin/env bash
set -euo pipefail

# 1. 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (or with sudo)."
    exit 1
fi

# 2. 检查 systemd 支持
if ! command -v systemctl &>/dev/null; then
    echo "[ERROR] systemd is required on this system."
    exit 1
fi

OVERRIDE_DIR="/etc/systemd/system/ssh.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

echo "[INFO] Creating systemd override directory..."
mkdir -p "${OVERRIDE_DIR}"

echo "[INFO] Writing SSH auto-restart & Tailscale dependency policy..."
cat << 'EOF' > "${OVERRIDE_FILE}"
[Unit]
# 强制在 Tailscale 服务启动之后再拉起 SSH
After=tailscaled.service
Wants=tailscaled.service

[Service]
# 清空 OpenSSH 默认的“禁止重启退出码”限制
RestartPreventExitStatus=
# 遇到任何退出（包括绑定失败的 Fatal 错误）都自动重启
Restart=always
# 每次重试等待 3 秒
RestartSec=3s
# 取消重试上限限制，永远重试直到 Tailscale IP 就绪
StartLimitIntervalSec=0
EOF

chmod 644 "${OVERRIDE_FILE}"

echo "[INFO] Reloading systemd daemon..."
systemctl daemon-reload

echo "[INFO] Restarting SSH service..."
if systemctl is-active --quiet sshd || systemctl list-unit-files | grep -q "^sshd.service"; then
    systemctl restart sshd.service || true
else
    systemctl restart ssh.service || true
fi

echo "[SUCCESS] SSH auto-restart strategy deployed successfully!"
