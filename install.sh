#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (or with sudo)."
    exit 1
fi

OVERRIDE_DIR="/etc/systemd/system/ssh.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

echo "[INFO] Creating systemd override directory..."
mkdir -p "${OVERRIDE_DIR}"

echo "[INFO] Writing SSH auto-restart policy..."
cat << 'EOF' > "${OVERRIDE_FILE}"
[Service]
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
EOF

chmod 644 "${OVERRIDE_FILE}"

echo "[INFO] Reloading systemd daemon..."
systemctl daemon-reload

echo "[INFO] Restarting SSH service..."
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true

echo "[SUCCESS] SSH auto-restart strategy deployed successfully!"
