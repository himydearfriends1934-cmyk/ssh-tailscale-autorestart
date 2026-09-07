```bash
#!/usr/bin/env bash
set -euo pipefail

# SSH Auto-Restart for Tailscale / VPN IP Binding
# https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart

echo "=============================================="
echo " SSH Auto-Restart for Tailscale / VPN IP"
echo "=============================================="
echo

# --------------------------------------------------
# 1. Check root privileges
# --------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root or with sudo."
    echo
    echo "Try:"
    echo "  sudo bash install.sh"
    exit 1
fi

# --------------------------------------------------
# 2. Check systemd
# --------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    echo "[ERROR] systemd is required on this system."
    exit 1
fi

# --------------------------------------------------
# 3. Detect SSH service
# --------------------------------------------------

SSH_SERVICE=""

if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh.service"
elif systemctl list-unit-files --type=service 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd.service"
elif systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE="ssh.service"
elif systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE="sshd.service"
else
    echo "[ERROR] Could not detect the SSH systemd service."
    echo
    echo "Please check manually with:"
    echo "  systemctl list-unit-files | grep -E '^ssh(d)?\.service'"
    exit 1
fi

echo "[INFO] Detected SSH service: ${SSH_SERVICE}"

# --------------------------------------------------
# 4. Detect Tailscale
# --------------------------------------------------

TAILSCALE_SERVICE=""

if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^tailscaled\.service'; then
    TAILSCALE_SERVICE="tailscaled.service"
elif systemctl cat tailscaled.service >/dev/null 2>&1; then
    TAILSCALE_SERVICE="tailscaled.service"
fi

if [[ -n "${TAILSCALE_SERVICE}" ]]; then
    echo "[INFO] Detected Tailscale service: ${TAILSCALE_SERVICE}"
else
    echo "[WARNING] tailscaled.service was not found."
    echo "[WARNING] The SSH restart policy will still be installed."
    echo
fi

# --------------------------------------------------
# 5. Create systemd override directory
# --------------------------------------------------

OVERRIDE_DIR="/etc/systemd/system/${SSH_SERVICE}.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

echo "[INFO] Creating systemd override directory:"
echo "       ${OVERRIDE_DIR}"

mkdir -p "${OVERRIDE_DIR}"

# --------------------------------------------------
# 6. Write systemd override
# --------------------------------------------------

echo "[INFO] Writing SSH auto-restart policy..."

if [[ -n "${TAILSCALE_SERVICE}" ]]; then

    cat > "${OVERRIDE_FILE}" <<EOF
[Unit]
# Start SSH after Tailscale service
After=${TAILSCALE_SERVICE}
Wants=${TAILSCALE_SERVICE}

[Service]
# Always restart SSH if it exits or fails
Restart=always

# Wait 3 seconds before restarting
RestartSec=3s

# Disable systemd start-rate limiting
StartLimitIntervalSec=0
EOF

else

    cat > "${OVERRIDE_FILE}" <<EOF
[Service]
# Always restart SSH if it exits or fails
Restart=always

# Wait 3 seconds before restarting
RestartSec=3s

# Disable systemd start-rate limiting
StartLimitIntervalSec=0
EOF

fi

chmod 644 "${OVERRIDE_FILE}"

# --------------------------------------------------
# 7. Reload systemd
# --------------------------------------------------

echo "[INFO] Reloading systemd daemon..."

systemctl daemon-reload

# --------------------------------------------------
# 8. Show installed configuration
# --------------------------------------------------

echo
echo "[INFO] Installed override:"
echo "----------------------------------------------"
cat "${OVERRIDE_FILE}"
echo "----------------------------------------------"
echo

# --------------------------------------------------
# 9. Restart SSH
# --------------------------------------------------

echo "[INFO] Restarting ${SSH_SERVICE}..."

# Do not allow an SSH restart failure to terminate
# the installation script.
if systemctl restart "${SSH_SERVICE}"; then
    echo "[INFO] SSH service restarted successfully."
else
    echo "[WARNING] SSH restart returned an error."
    echo "[WARNING] The systemd auto-restart policy is still installed."
    echo
    echo "Check SSH status with:"
    echo "  systemctl status ${SSH_SERVICE}"
    echo
    echo "Check SSH logs with:"
    echo "  journalctl -u ${SSH_SERVICE} -b --no-pager"
fi

# --------------------------------------------------
# 10. Verify systemd configuration
# --------------------------------------------------

echo
echo "[INFO] Verifying systemd configuration..."

if systemctl cat "${SSH_SERVICE}" >/dev/null 2>&1; then
    echo "[INFO] systemd configuration loaded successfully."
else
    echo "[WARNING] Could not verify the SSH systemd configuration."
fi

# --------------------------------------------------
# 11. Final message
# --------------------------------------------------

echo
echo "=============================================="
echo " Installation completed"
echo "=============================================="
echo
echo "SSH service:"
echo "  ${SSH_SERVICE}"
echo
echo "Override file:"
echo "  ${OVERRIDE_FILE}"
echo

if [[ -n "${TAILSCALE_SERVICE}" ]]; then
    echo "Tailscale dependency:"
    echo "  ${TAILSCALE_SERVICE}"
    echo
fi

echo "Useful commands:"
echo
echo "  systemctl status ${SSH_SERVICE}"
echo "  systemctl cat ${SSH_SERVICE}"
echo "  journalctl -u ${SSH_SERVICE} -b --no-pager"
echo

echo "[SUCCESS] SSH auto-restart strategy deployed successfully!"
```
