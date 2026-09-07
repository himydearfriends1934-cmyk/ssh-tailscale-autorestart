```bash
#!/usr/bin/env bash
set -euo pipefail

# SSH Auto-Restart for Tailscale / VPN IP Binding
# https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart

OVERRIDE_NAME="override.conf"

# --------------------------------------------------
# Root check
# --------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "[ERROR] Please run this script as root."
    echo
    echo "Example:"
    echo "  curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash"
    echo
    exit 1
fi

# --------------------------------------------------
# systemd check
# --------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    echo
    echo "[ERROR] systemd is required."
    echo
    exit 1
fi

# --------------------------------------------------
# Detect SSH service
# --------------------------------------------------

detect_ssh_service() {
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

    if ! SSH_SERVICE="$(detect_ssh_service)"; then
        echo "[ERROR] SSH service was not found."
        echo
        echo "Try:"
        echo "  systemctl list-unit-files | grep -E '^ssh(d)?\\.service'"
        echo
        return 1
    fi

    echo "[INFO] SSH service: ${SSH_SERVICE}"

    TAILSCALE_SERVICE=""

    if TAILSCALE_SERVICE="$(detect_tailscale)"; then
        echo "[INFO] Tailscale: ${TAILSCALE_SERVICE}"
    else
        echo "[INFO] Tailscale service not detected."
        echo "[INFO] Installing generic SSH auto-restart."
    fi

    OVERRIDE_DIR="/etc/systemd/system/${SSH_SERVICE}.d"
    OVERRIDE_FILE="${OVERRIDE_DIR}/${OVERRIDE_NAME}"

    echo
    echo "[INFO] Creating:"
    echo "       ${OVERRIDE_FILE}"

    mkdir -p "${OVERRIDE_DIR}"

    if [[ -n "${TAILSCALE_SERVICE}" ]]; then

        cat > "${OVERRIDE_FILE}" <<EOF
[Unit]
After=${TAILSCALE_SERVICE}
Wants=${TAILSCALE_SERVICE}
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3s
EOF

    else

        cat > "${OVERRIDE_FILE}" <<EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=3s
EOF

    fi

    chmod 644 "${OVERRIDE_FILE}"

    echo
    echo "[INFO] Reloading systemd..."
    systemctl daemon-reload

    echo "[INFO] Restarting ${SSH_SERVICE}..."

    if systemctl restart "${SSH_SERVICE}"; then
        echo "[SUCCESS] SSH restarted successfully."
    else
        echo "[WARNING] SSH restart failed."
        echo
        echo "Check:"
        echo "  systemctl status ${SSH_SERVICE}"
        echo
        echo "  journalctl -u ${SSH_SERVICE} -b --no-pager"
        return 1
    fi

    echo
    echo "=============================================="
    echo " Installation completed"
    echo "=============================================="
    echo
    echo "SSH service:"
    echo "  ${SSH_SERVICE}"
    echo
    echo "Configuration:"
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

    for SERVICE in ssh.service sshd.service; do

        OVERRIDE_DIR="/etc/systemd/system/${SERVICE}.d"
        OVERRIDE_FILE="${OVERRIDE_DIR}/${OVERRIDE_NAME}"

        if [[ -f "${OVERRIDE_FILE}" ]]; then

            echo "[INFO] Removing:"
            echo "       ${OVERRIDE_FILE}"

            rm -f "${OVERRIDE_FILE}"
            REMOVED=1

        fi

        if [[ -d "${OVERRIDE_DIR}" ]]; then
            rmdir "${OVERRIDE_DIR}" 2>/dev/null || true
        fi

    done

    echo
    echo "[INFO] Reloading systemd..."
    systemctl daemon-reload

    if SSH_SERVICE="$(detect_ssh_service)"; then

        echo "[INFO] Restarting ${SSH_SERVICE}..."

        if systemctl restart "${SSH_SERVICE}"; then
            echo "[SUCCESS] SSH restarted successfully."
        else
            echo "[WARNING] SSH restart failed."
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
        echo "[INFO] No configuration was found."
        echo

    fi
}

# --------------------------------------------------
# Menu
# --------------------------------------------------

while true; do

    echo
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
            ;;

        2)
            uninstall_ssh_policy
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
            ;;

    esac

done
```
