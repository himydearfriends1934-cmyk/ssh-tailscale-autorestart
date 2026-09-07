#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SSH Auto-Restart for Tailscale / VPN IP Binding
# Version: 2.0
#
# Features:
#   - Detect ssh.service / sshd.service
#   - Detect tailscaled.service
#   - Watch actual Tailscale IPv4 address
#   - Restart SSH when Tailscale IP appears / changes
#   - Restart SSH when the service itself fails
#   - Validate sshd configuration before restart
#   - Clean install / uninstall
#
# Project:
# https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart
# ============================================================

set +e

PROJECT_NAME="ssh-tailscale-autorestart"
WATCHER_PATH="/usr/local/sbin/tailscale-ssh-watch"
WATCHER_SERVICE="tailscale-ssh-watch.service"
OVERRIDE_NAME="override.conf"

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "[ERROR] Please run this script as root."
    echo
    echo "Example:"
    echo "  curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash"
    echo
    exit 1
fi

# ------------------------------------------------------------
# systemd check
# ------------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    echo
    echo "[ERROR] systemd is required."
    echo
    exit 1
fi

# ------------------------------------------------------------
# Detect SSH service
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Detect Tailscale service
# ------------------------------------------------------------

detect_tailscale_service() {
    if systemctl cat tailscaled.service >/dev/null 2>&1; then
        echo "tailscaled.service"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Detect Tailscale command
# ------------------------------------------------------------

detect_tailscale_command() {
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Detect sshd binary
# ------------------------------------------------------------

detect_sshd_binary() {
    if command -v sshd >/dev/null 2>&1; then
        command -v sshd
        return 0
    fi

    if [[ -x "/usr/sbin/sshd" ]]; then
        echo "/usr/sbin/sshd"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------
# Validate SSH configuration
# ------------------------------------------------------------

validate_sshd_config() {
    local SSHD_BIN

    if ! SSHD_BIN="$(detect_sshd_binary)"; then
        echo "[WARNING] sshd binary was not found."
        echo "[WARNING] Cannot validate SSH configuration."
        return 1
    fi

    echo "[INFO] Validating SSH configuration..."

    if "${SSHD_BIN}" -t; then
        echo "[SUCCESS] SSH configuration is valid."
        return 0
    fi

    echo
    echo "[ERROR] SSH configuration validation failed."
    echo
    echo "Run:"
    echo "  ${SSHD_BIN} -t"
    echo
    return 1
}

# ------------------------------------------------------------
# Create watcher script
# ------------------------------------------------------------

create_watcher_script() {

    echo "[INFO] Installing Tailscale IP watcher:"
    echo "       ${WATCHER_PATH}"

    cat > "${WATCHER_PATH}" <<'WATCHER_EOF'
#!/usr/bin/env bash
set -u

SSH_SERVICE="${SSH_SERVICE:-ssh.service}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"

log() {
    echo "[tailscale-ssh-watch] $*"
}

get_tailscale_ip() {
    local IP=""

    if ! command -v tailscale >/dev/null 2>&1; then
        return 1
    fi

    IP="$(tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"

    if [[ "${IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "${IP}"
        return 0
    fi

    return 1
}

validate_ssh() {
    local SSHD_BIN=""

    if command -v sshd >/dev/null 2>&1; then
        SSHD_BIN="$(command -v sshd)"
    elif [[ -x "/usr/sbin/sshd" ]]; then
        SSHD_BIN="/usr/sbin/sshd"
    else
        log "WARNING: sshd binary not found."
        return 1
    fi

    if ! "${SSHD_BIN}" -t >/dev/null 2>&1; then
        log "ERROR: SSH configuration is invalid."
        log "SSH restart skipped."
        return 1
    fi

    return 0
}

restart_ssh() {

    log "Validating SSH configuration..."

    if ! validate_ssh; then
        return 1
    fi

    log "Restarting ${SSH_SERVICE}..."

    if systemctl restart "${SSH_SERVICE}"; then
        log "SSH restarted successfully."
        return 0
    fi

    log "WARNING: failed to restart ${SSH_SERVICE}."
    return 1
}

if ! command -v systemctl >/dev/null 2>&1; then
    log "ERROR: systemctl not found."
    exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
    log "ERROR: tailscale command not found."
    exit 1
fi

if ! systemctl cat "${SSH_SERVICE}" >/dev/null 2>&1; then
    log "ERROR: SSH service ${SSH_SERVICE} not found."
    exit 1
fi

log "Starting Tailscale IP watcher."
log "SSH service: ${SSH_SERVICE}"
log "Check interval: ${CHECK_INTERVAL}s"

PREVIOUS_IP=""

while true; do

    CURRENT_IP=""

    if CURRENT_IP="$(get_tailscale_ip)"; then

        if [[ -z "${PREVIOUS_IP}" ]]; then

            log "Tailscale IPv4 detected: ${CURRENT_IP}"

            # Tailscale IP has just appeared.
            # Restart SSH so ListenAddress bindings can be recreated.
            restart_ssh

        elif [[ "${CURRENT_IP}" != "${PREVIOUS_IP}" ]]; then

            log "Tailscale IPv4 changed:"
            log "  old: ${PREVIOUS_IP}"
            log "  new: ${CURRENT_IP}"

            restart_ssh
        fi

        PREVIOUS_IP="${CURRENT_IP}"

    else

        if [[ -n "${PREVIOUS_IP}" ]]; then
            log "Tailscale IPv4 disappeared."
            log "Waiting for Tailscale IPv4 to return."
            PREVIOUS_IP=""
        fi

    fi

    sleep "${CHECK_INTERVAL}"
done
WATCHER_EOF

    chmod 755 "${WATCHER_PATH}"
}

# ------------------------------------------------------------
# Create systemd watcher service
# ------------------------------------------------------------

create_watcher_service() {

    local SERVICE_FILE="/etc/systemd/system/${WATCHER_SERVICE}"

    echo "[INFO] Installing systemd watcher:"
    echo "       ${SERVICE_FILE}"

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Watch Tailscale IPv4 and restart SSH when it changes
After=network-online.target tailscaled.service ${SSH_SERVICE}
Wants=network-online.target tailscaled.service
Requires=${SSH_SERVICE}

[Service]
Type=simple
ExecStart=${WATCHER_PATH}
Restart=always
RestartSec=3s

# Environment
Environment=SSH_SERVICE=${SSH_SERVICE}
Environment=CHECK_INTERVAL=2

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${SERVICE_FILE}"
}

# ------------------------------------------------------------
# Create SSH systemd override
# ------------------------------------------------------------

create_ssh_override() {

    local OVERRIDE_DIR="/etc/systemd/system/${SSH_SERVICE}.d"
    local OVERRIDE_FILE="${OVERRIDE_DIR}/${OVERRIDE_NAME}"

    echo "[INFO] Creating SSH systemd override:"
    echo "       ${OVERRIDE_FILE}"

    mkdir -p "${OVERRIDE_DIR}"

    cat > "${OVERRIDE_FILE}" <<EOF
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=on-failure
RestartSec=3s
EOF

    chmod 644 "${OVERRIDE_FILE}"
}

# ------------------------------------------------------------
# Install
# ------------------------------------------------------------

install_ssh_policy() {

    echo
    echo "=============================================="
    echo " Installing SSH Auto-Restart v2"
    echo "=============================================="
    echo

    # --------------------------------------------------------
    # Detect SSH
    # --------------------------------------------------------

    if ! SSH_SERVICE="$(detect_ssh_service)"; then
        echo "[ERROR] SSH service was not found."
        echo
        echo "Try:"
        echo "  systemctl list-unit-files | grep -E '^ssh(d)?\\.service'"
        echo
        return 1
    fi

    echo "[INFO] SSH service: ${SSH_SERVICE}"

    # --------------------------------------------------------
    # Detect Tailscale
    # --------------------------------------------------------

    if ! TAILSCALE_SERVICE="$(detect_tailscale_service)"; then
        echo
        echo "[ERROR] tailscaled.service was not found."
        echo
        echo "This version requires Tailscale."
        echo
        return 1
    fi

    echo "[INFO] Tailscale service: ${TAILSCALE_SERVICE}"

    if ! TAILSCALE_COMMAND="$(detect_tailscale_command)"; then
        echo
        echo "[ERROR] tailscale command was not found."
        echo
        echo "Install Tailscale first, then run this installer again."
        echo
        return 1
    fi

    echo "[INFO] Tailscale command: ${TAILSCALE_COMMAND}"

    # --------------------------------------------------------
    # Check Tailscale service
    # --------------------------------------------------------

    if ! systemctl is-active --quiet tailscaled.service; then
        echo
        echo "[INFO] tailscaled.service is not running."
        echo "[INFO] Starting Tailscale..."

        if ! systemctl start tailscaled.service; then
            echo
            echo "[ERROR] Failed to start tailscaled.service."
            echo
            return 1
        fi
    fi

    # --------------------------------------------------------
    # Check SSH configuration BEFORE changing anything
    # --------------------------------------------------------

    if ! validate_sshd_config; then
        echo
        echo "[ERROR] Installation aborted."
        echo "[ERROR] Fix the SSH configuration first."
        echo
        return 1
    fi

    # --------------------------------------------------------
    # Create files
    # --------------------------------------------------------

    create_watcher_script
    create_watcher_service
    create_ssh_override

    # --------------------------------------------------------
    # Reload systemd
    # --------------------------------------------------------

    echo
    echo "[INFO] Reloading systemd..."

    if ! systemctl daemon-reload; then
        echo "[ERROR] systemd daemon-reload failed."
        return 1
    fi

    # --------------------------------------------------------
    # Enable watcher
    # --------------------------------------------------------

    echo "[INFO] Enabling watcher service..."

    if ! systemctl enable "${WATCHER_SERVICE}"; then
        echo "[ERROR] Failed to enable watcher service."
        return 1
    fi

    # --------------------------------------------------------
    # Restart SSH
    # --------------------------------------------------------

    echo
    echo "[INFO] Restarting ${SSH_SERVICE}..."

    if systemctl restart "${SSH_SERVICE}"; then
        echo "[SUCCESS] SSH restarted successfully."
    else
        echo
        echo "[ERROR] SSH restart failed."
        echo
        echo "Check:"
        echo "  systemctl status ${SSH_SERVICE}"
        echo
        echo "  journalctl -u ${SSH_SERVICE} -b --no-pager"
        echo

        # Do not start watcher if SSH itself cannot start.
        return 1
    fi

    # --------------------------------------------------------
    # Start watcher
    # --------------------------------------------------------

    echo
    echo "[INFO] Starting ${WATCHER_SERVICE}..."

    if systemctl restart "${WATCHER_SERVICE}"; then
        echo "[SUCCESS] Tailscale SSH watcher started."
    else
        echo
        echo "[ERROR] Failed to start Tailscale SSH watcher."
        echo
        echo "Check:"
        echo "  systemctl status ${WATCHER_SERVICE}"
        echo
        echo "  journalctl -u ${WATCHER_SERVICE} -b --no-pager"
        echo
        return 1
    fi

    # --------------------------------------------------------
    # Show status
    # --------------------------------------------------------

    echo
    echo "=============================================="
    echo " Installation completed"
    echo "=============================================="
    echo

    echo "SSH service:"
    echo "  ${SSH_SERVICE}"
    echo

    echo "Tailscale service:"
    echo "  ${TAILSCALE_SERVICE}"
    echo

    echo "SSH configuration:"
    echo "  /etc/systemd/system/${SSH_SERVICE}.d/${OVERRIDE_NAME}"
    echo

    echo "Watcher:"
    echo "  ${WATCHER_PATH}"
    echo

    echo "Watcher service:"
    echo "  ${WATCHER_SERVICE}"
    echo

    echo "Useful commands:"
    echo
    echo "  systemctl status ${SSH_SERVICE}"
    echo
    echo "  systemctl status ${WATCHER_SERVICE}"
    echo
    echo "  journalctl -u ${WATCHER_SERVICE} -f"
    echo
    echo "  tailscale ip -4"
    echo
}

# ------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------

uninstall_ssh_policy() {

    echo
    echo "=============================================="
    echo " Uninstalling SSH Auto-Restart v2"
    echo "=============================================="
    echo

    REMOVED=0

    # --------------------------------------------------------
    # Stop watcher
    # --------------------------------------------------------

    if systemctl list-unit-files "${WATCHER_SERVICE}" >/dev/null 2>&1; then

        echo "[INFO] Stopping ${WATCHER_SERVICE}..."

        systemctl stop "${WATCHER_SERVICE}" >/dev/null 2>&1 || true

        echo "[INFO] Disabling ${WATCHER_SERVICE}..."

        systemctl disable "${WATCHER_SERVICE}" >/dev/null 2>&1 || true

    fi

    # --------------------------------------------------------
    # Remove watcher service
    # --------------------------------------------------------

    WATCHER_SERVICE_FILE="/etc/systemd/system/${WATCHER_SERVICE}"

    if [[ -f "${WATCHER_SERVICE_FILE}" ]]; then

        echo "[INFO] Removing:"
        echo "       ${WATCHER_SERVICE_FILE}"

        rm -f "${WATCHER_SERVICE_FILE}"
        REMOVED=1
    fi

    # --------------------------------------------------------
    # Remove watcher script
    # --------------------------------------------------------

    if [[ -f "${WATCHER_PATH}" ]]; then

        echo "[INFO] Removing:"
        echo "       ${WATCHER_PATH}"

        rm -f "${WATCHER_PATH}"
        REMOVED=1
    fi

    # --------------------------------------------------------
    # Remove SSH override
    # --------------------------------------------------------

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

    # --------------------------------------------------------
    # Reload systemd
    # --------------------------------------------------------

    echo
    echo "[INFO] Reloading systemd..."

    systemctl daemon-reload

    # --------------------------------------------------------
    # Restart SSH without project override
    # --------------------------------------------------------

    if SSH_SERVICE="$(detect_ssh_service)"; then

        echo
        echo "[INFO] Restarting ${SSH_SERVICE}..."

        if validate_sshd_config; then

            if systemctl restart "${SSH_SERVICE}"; then
                echo "[SUCCESS] SSH restarted successfully."
            else
                echo "[WARNING] SSH restart failed."
                echo
                echo "Check:"
                echo "  systemctl status ${SSH_SERVICE}"
            fi

        else

            echo "[WARNING] SSH configuration is invalid."
            echo "[WARNING] SSH was not restarted."
        fi

    fi

    # --------------------------------------------------------
    # Result
    # --------------------------------------------------------

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

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

while true; do

    echo
    echo "=============================================="
    echo " SSH Auto-Restart for Tailscale / VPN IP"
    echo " Version 2.0"
    echo "=============================================="
    echo
    echo "  1) Install"
    echo "  2) Uninstall"
    echo "  3) Exit"
    echo
    read -r -p "Please select [1-3]: " CHOICE

    case "${CHOICE}" in

        1)
            if ! install_ssh_policy; then
                echo
                echo "[ERROR] Installation failed."
                echo
                exit 1
            fi
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
