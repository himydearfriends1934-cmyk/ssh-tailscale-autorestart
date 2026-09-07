```bash
#!/usr/bin/env bash
set -euo pipefail

# SSH Auto-Restart for Tailscale / VPN IP Binding
# https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart

# --------------------------------------------------
# Check root
# --------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "[ERROR] This script must be run as root or with sudo."
    echo
    echo "Please run:"
    echo "  sudo bash install.sh"
    echo
    exit 1
fi

# --------------------------------------------------
# Check systemd
# --------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    echo
    echo "[ERROR] systemd is required on this system."
    echo
    exit 1
fi

# --------------------------------------------------
# Detect SSH service
# --------------------------------------------------

detect_ssh_service() {

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^ssh\.service'; then
        echo "ssh.service"
        return 0
    fi

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^sshd\.service'; then
        echo "sshd.service"
        return 0
    fi

    if systemctl cat ssh.service >/dev/null 2>&1; then
        echo "ssh.service"
        return 0
    fi

    if systemctl cat sshd.service >/dev/null 2>&1; then
        echo "sshd.service"
        return 0
    fi

    return 1
}

# --------------------------------------------------
# Detect Tailscale
# --------------------------------------------------

detect_tailscale() {

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^tailscaled\.service'; then
        echo "tailscaled.service"
        return 0
    fi

    if systemctl cat tailscaled.service >/dev/null 2>&1; then
        echo "tailscaled.service"
        return 0
    fi

    return 1
}

# --------------------------------------------------
# Install
# --------------------------------------------------

install_ssh_policy() {

    echo
    echo "=============================================="
    echo " Installing SSH Auto-Restart"
    echo "=============================================="
    echo

    # Detect SSH
    if ! SSH_SERVICE="$(detect_ssh_service)"; then
        echo "[ERROR] Could not detect SSH service."
        echo
        echo "Check with:"
        echo "  systemctl list-unit-files | grep -E '^ssh(d)?\.service'"
        echo
        exit 1
    fi

    echo "[INFO] SSH service detected: ${SSH_SERVICE}"

    # Detect Tailscale
    TAILSCALE_SERVICE=""

    if TAILSCALE_SERVICE="$(detect_tailscale)"; then
        echo "[INFO] Tailscale detected: ${TAILSCALE_SERVICE}"
    else
        echo "[WARNING] Tailscale service was not detected."
        echo "[WARNING] SSH auto-restart will still be installed."
        echo "[WARNING] No Tailscale dependency will be added."
    fi

    # Override path
    OVERRIDE_DIR="/etc/systemd/system/${SSH_SERVICE}.d"
    OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"

    echo
    echo "[INFO] Creating:"
    echo "       ${OVERRIDE_DIR}"

    mkdir -p "${OVERRIDE_DIR}"

    # Write configuration
    echo "[INFO] Writing systemd configuration..."

    if [[ -n "${TAILSCALE_SERVICE}" ]]; then

        cat > "${OVERRIDE_FILE}" <<EOF
[Unit]
# Start SSH after Tailscale
After=${TAILSCALE_SERVICE}
Wants=${TAILSCALE_SERVICE}

[Service]
# Automatically restart SSH if it exits or fails
Restart=always

# Wait 3 seconds before restarting
RestartSec=3s

# Disable systemd start-rate limiting
StartLimitIntervalSec=0
EOF

    else

        cat > "${OVERRIDE_FILE}" <<EOF
[Service]
# Automatically restart SSH if it exits or fails
Restart=always

# Wait 3 seconds before restarting
RestartSec=3s

# Disable systemd start-rate limiting
StartLimitIntervalSec=0
EOF

    fi

    chmod 644 "${OVERRIDE_FILE}"

    # Reload systemd
    echo
    echo "[INFO] Reloading systemd..."

    systemctl daemon-reload

    # Restart SSH
    echo "[INFO] Restarting ${SSH_SERVICE}..."

    if systemctl restart "${SSH_SERVICE}"; then
        echo "[INFO] SSH restarted successfully."
    else
        echo
        echo "[WARNING] SSH restart returned an error."
        echo
        echo "Check status:"
        echo "  systemctl status ${SSH_SERVICE}"
        echo
        echo "Check logs:"
        echo "  journalctl -u ${SSH_SERVICE} -b --no-pager"
    fi

    # Show configuration
    echo
    echo "=============================================="
    echo " Installation completed"
    echo "=============================================="
    echo
    echo "SSH service:"
    echo "  ${SSH_SERVICE}"
    echo
    echo "Override:"
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
}

# --------------------------------------------------
# Uninstall
# --------------------------------------------------

uninstall_ssh_policy() {

    echo
    echo "=============================================="
    echo " Uninstalling SSH Auto-Restart"
    echo "=============================================="
    echo

    REMOVED=0

    # Remove ssh.service override
    SSH_OVERRIDE="/etc/systemd/system/ssh.service.d/override.conf"

    if [[ -f "${SSH_OVERRIDE}" ]]; then
        echo "[INFO] Removing:"
        echo "       ${SSH_OVERRIDE}"

        rm -f "${SSH_OVERRIDE}"
        REMOVED=1
    fi

    # Remove empty directory
    if [[ -d "/etc/systemd/system/ssh.service.d" ]]; then
        rmdir "/etc/systemd/system/ssh.service.d" 2>/dev/null || true
    fi

    # Remove sshd.service override
    SSHD_OVERRIDE="/etc/systemd/system/sshd.service.d/override.conf"

    if [[ -f "${SSHD_OVERRIDE}" ]]; then
        echo "[INFO] Removing:"
        echo "       ${SSHD_OVERRIDE}"

        rm -f "${SSHD_OVERRIDE}"
        REMOVED=1
    fi

    # Remove empty directory
    if [[ -d "/etc/systemd/system/sshd.service.d" ]]; then
        rmdir "/etc/systemd/system/sshd.service.d" 2>/dev/null || true
    fi

    # Reload systemd
    echo
    echo "[INFO] Reloading systemd..."

    systemctl daemon-reload

    # Detect SSH service
    SSH_SERVICE=""

    if SSH_SERVICE="$(detect_ssh_service)"; then

        echo "[INFO] Restarting ${SSH_SERVICE}..."

        if systemctl restart "${SSH_SERVICE}"; then
            echo "[INFO] SSH restarted successfully."
        else
            echo "[WARNING] SSH restart returned an error."
        fi

    fi

    echo

    if [[ "${REMOVED}" -eq 1 ]]; then

        echo "=============================================="
        echo " Uninstallation completed"
        echo "=============================================="
        echo
        echo "[SUCCESS] SSH auto-restart has been removed."
        echo

    else

        echo "=============================================="
        echo " Nothing to uninstall"
        echo "=============================================="
        echo
        echo "[INFO] No SSH auto-restart configuration was found."
        echo

    fi
}

# --------------------------------------------------
# Menu
# --------------------------------------------------

while true; do

    clear

    echo "=============================================="
    echo " SSH Auto-Restart for Tailscale / VPN IP"
    echo "=============================================="
    echo
    echo "  1) Install"
    echo "  2) Uninstall"
    echo "  3) Exit"
    echo
    read -r -p "Please select [1-3]: " CHOICE

    case "${CHOICE}" in

        1)
            install_ssh_policy
            echo
            read -r -p "Press Enter to return to the menu..."
            ;;

        2)
            uninstall_ssh_policy
            echo
            read -r -p "Press Enter to return to the menu..."
            ;;

        3)
            echo
            echo "[INFO] Exiting."
            echo
            exit 0
            ;;

        *)
            echo
            echo "[ERROR] Invalid selection."
            echo
            read -r -p "Press Enter to try again..."
            ;;

    esac

done
```
