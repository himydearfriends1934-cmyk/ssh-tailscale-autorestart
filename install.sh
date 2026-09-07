#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SSH Auto-Restart for Tailscale / VPN IP Binding
# Version: 2.1
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

PROJECT_NAME="ssh-tailscale-autorestart"
WATCHER_PATH="/usr/local/sbin/tailscale-ssh-watch"
WATCHER_SERVICE="tailscale-ssh-watch.service"
OVERRIDE_NAME="90-tailscale-ssh-autorestart.conf"
MANAGED_HEADER="# Managed by ${PROJECT_NAME}"

declare -a INSTALL_BACKUP_FILES=()
declare -a INSTALL_CREATED_FILES=()
INSTALL_BACKUP_DIR=""
WATCHER_WAS_ENABLED=0
WATCHER_WAS_ACTIVE=0

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo
    echo "[ERROR] Please run this script as root."
    echo
    echo "Example:"
    echo "  curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash -s -- install"
    echo
    exit 1
fi

# ------------------------------------------------------------
# File ownership and install rollback helpers
# ------------------------------------------------------------

is_managed_file() {
    local FILE="$1"

    [[ -f "${FILE}" ]] &&
        grep -Fqx "${MANAGED_HEADER}" "${FILE}"
}

is_legacy_watcher_script() {
    local FILE="$1"

    [[ -f "${FILE}" ]] &&
        grep -Fq "[tailscale-ssh-watch]" "${FILE}" &&
        grep -Fq "tailscale ip -4" "${FILE}" &&
        grep -Fq "PREVIOUS_IP" "${FILE}"
}

is_legacy_watcher_service() {
    local FILE="$1"

    [[ -f "${FILE}" ]] &&
        grep -Fqx "ExecStart=${WATCHER_PATH}" "${FILE}" &&
        grep -Fq "Description=Watch Tailscale IPv4 and restart SSH when it changes" "${FILE}"
}

is_legacy_ssh_override() {
    local FILE="$1"

    [[ -f "${FILE}" ]] &&
        (
            (
                grep -Fqx "After=tailscaled.service" "${FILE}" &&
                grep -Fqx "Wants=tailscaled.service" "${FILE}" &&
                grep -Fqx "RestartSec=3s" "${FILE}" &&
                (grep -Fqx "Restart=on-failure" "${FILE}" ||
                    grep -Fqx "Restart=always" "${FILE}")
            ) ||
            (
                grep -Fqx "Restart=always" "${FILE}" &&
                grep -Fqx "RestartSec=5s" "${FILE}" &&
                grep -Fqx "StartLimitIntervalSec=0" "${FILE}"
            )
        )
}

prepare_target() {
    local FILE="$1"
    local BACKUP

    if [[ -e "${FILE}" && ! -f "${FILE}" ]]; then
        echo "[ERROR] Target is not a regular file: ${FILE}"
        return 1
    fi

    if [[ -f "${FILE}" ]] &&
       ! is_managed_file "${FILE}" &&
       ! is_legacy_watcher_script "${FILE}" &&
       ! is_legacy_watcher_service "${FILE}" &&
       ! is_legacy_ssh_override "${FILE}"; then
        echo "[ERROR] Refusing to overwrite an unmanaged file:"
        echo "        ${FILE}"
        echo "[ERROR] Remove it manually only after verifying its contents."
        return 1
    fi

    if [[ -f "${FILE}" ]]; then
        BACKUP="${INSTALL_BACKUP_DIR}${FILE}"
        if ! mkdir -p "$(dirname "${BACKUP}")" || ! cp -a -- "${FILE}" "${BACKUP}"; then
            echo "[ERROR] Failed to back up ${FILE}."
            return 1
        fi
        INSTALL_BACKUP_FILES+=("${FILE}")
    else
        INSTALL_CREATED_FILES+=("${FILE}")
    fi
}

rollback_install() {
    local FILE
    local BACKUP
    systemctl disable --now "${WATCHER_SERVICE}" >/dev/null 2>&1 || true

    for FILE in "${INSTALL_CREATED_FILES[@]}"; do
        rm -f -- "${FILE}"
    done

    for FILE in "${INSTALL_BACKUP_FILES[@]}"; do
        BACKUP="${INSTALL_BACKUP_DIR}${FILE}"
        if [[ -f "${BACKUP}" ]]; then
            cp -a -- "${BACKUP}" "${FILE}"
        fi
    done

    systemctl daemon-reload >/dev/null 2>&1 || true

    if [[ -n "${SSH_SERVICE:-}" ]]; then
        systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1 || true
    fi

    if [[ "${WATCHER_WAS_ENABLED}" -eq 1 ]]; then
        systemctl enable --now "${WATCHER_SERVICE}" >/dev/null 2>&1 || true
    elif [[ "${WATCHER_WAS_ACTIVE}" -eq 1 ]]; then
        systemctl start "${WATCHER_SERVICE}" >/dev/null 2>&1 || true
    fi

    if [[ -n "${INSTALL_BACKUP_DIR}" && -d "${INSTALL_BACKUP_DIR}" ]]; then
        rm -rf -- "${INSTALL_BACKUP_DIR}"
    fi

    INSTALL_BACKUP_FILES=()
    INSTALL_CREATED_FILES=()
    INSTALL_BACKUP_DIR=""
    WATCHER_WAS_ENABLED=0
    WATCHER_WAS_ACTIVE=0
}

finish_install() {
    if [[ -n "${INSTALL_BACKUP_DIR}" && -d "${INSTALL_BACKUP_DIR}" ]]; then
        rm -rf -- "${INSTALL_BACKUP_DIR}"
    fi

    INSTALL_BACKUP_FILES=()
    INSTALL_CREATED_FILES=()
    INSTALL_BACKUP_DIR=""
    WATCHER_WAS_ENABLED=0
    WATCHER_WAS_ACTIVE=0
}

remove_managed_file() {
    local FILE="$1"

    if [[ ! -e "${FILE}" ]]; then
        return 0
    fi

    if ! is_managed_file "${FILE}" &&
       ! is_legacy_watcher_script "${FILE}" &&
       ! is_legacy_watcher_service "${FILE}" &&
       ! is_legacy_ssh_override "${FILE}"; then
        echo "[WARNING] Preserving unmanaged file:"
        echo "          ${FILE}"
        return 1
    fi

    rm -f -- "${FILE}"
}

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
    local SERVICE

    for SERVICE in ssh.service sshd.service; do
        if systemctl is-active --quiet "${SERVICE}"; then
            echo "${SERVICE}"
            return 0
        fi
    done

    for SERVICE in ssh.service sshd.service; do
        if systemctl is-enabled --quiet "${SERVICE}"; then
            echo "${SERVICE}"
            return 0
        fi
    done

    for SERVICE in ssh.service sshd.service; do
        if systemctl cat "${SERVICE}" >/dev/null 2>&1; then
            echo "${SERVICE}"
            return 0
        fi
    done

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

    if ! cat > "${WATCHER_PATH}" <<'WATCHER_EOF'
#!/usr/bin/env bash
# Managed by ssh-tailscale-autorestart
set -u

SSH_SERVICE="${SSH_SERVICE:-ssh.service}"
TAILSCALE_COMMAND="${TAILSCALE_COMMAND:-tailscale}"
CHECK_INTERVAL="${CHECK_INTERVAL:-2}"

log() {
    echo "[tailscale-ssh-watch] $*"
}

get_tailscale_ip() {
    local IP=""
    local OCTET
    local OCTETS

    IP="$("${TAILSCALE_COMMAND}" ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')" || return 1

    if [[ "${IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        IFS='.' read -r -a OCTETS <<< "${IP}"
        for OCTET in "${OCTETS[@]}"; do
            if ((10#${OCTET} > 255)); then
                return 1
            fi
        done
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

if [[ "${TAILSCALE_COMMAND}" == */* ]]; then
    if [[ ! -x "${TAILSCALE_COMMAND}" ]]; then
        log "ERROR: Tailscale command not found: ${TAILSCALE_COMMAND}"
        exit 1
    fi
elif ! command -v "${TAILSCALE_COMMAND}" >/dev/null 2>&1; then
    log "ERROR: Tailscale command not found: ${TAILSCALE_COMMAND}"
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

            # Restart SSH so ListenAddress bindings can be recreated.
            if restart_ssh; then
                PREVIOUS_IP="${CURRENT_IP}"
            fi

        elif [[ "${CURRENT_IP}" != "${PREVIOUS_IP}" ]]; then

            log "Tailscale IPv4 changed:"
            log "  old: ${PREVIOUS_IP}"
            log "  new: ${CURRENT_IP}"

            if restart_ssh; then
                PREVIOUS_IP="${CURRENT_IP}"
            fi
        fi

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
    then
        return 1
    fi

    if ! chmod 755 "${WATCHER_PATH}"; then
        return 1
    fi
}

# ------------------------------------------------------------
# Create systemd watcher service
# ------------------------------------------------------------

create_watcher_service() {

    local SERVICE_FILE="/etc/systemd/system/${WATCHER_SERVICE}"

    echo "[INFO] Installing systemd watcher:"
    echo "       ${SERVICE_FILE}"

    if ! cat > "${SERVICE_FILE}" <<EOF
[Unit]
# Managed by ssh-tailscale-autorestart
Description=Watch Tailscale IPv4 and restart SSH when it changes
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=${WATCHER_PATH}
Restart=always
RestartSec=3s

# Environment
Environment="SSH_SERVICE=${SSH_SERVICE}"
Environment="TAILSCALE_COMMAND=${TAILSCALE_COMMAND}"
Environment=CHECK_INTERVAL=2

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    then
        return 1
    fi

    if ! chmod 644 "${SERVICE_FILE}"; then
        return 1
    fi
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

    if ! cat > "${OVERRIDE_FILE}" <<EOF
[Unit]
# Managed by ssh-tailscale-autorestart
After=tailscaled.service
Wants=tailscaled.service
StartLimitIntervalSec=0

[Service]
RestartPreventExitStatus=
Restart=on-failure
RestartSec=3s
EOF
    then
        return 1
    fi

    if ! chmod 644 "${OVERRIDE_FILE}"; then
        return 1
    fi
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
    # Prepare files and backups before changing anything
    # --------------------------------------------------------

    if ! INSTALL_BACKUP_DIR="$(mktemp -d "/tmp/${PROJECT_NAME}.XXXXXX")"; then
        echo "[ERROR] Failed to create a temporary backup directory."
        return 1
    fi

    LEGACY_OVERRIDE_FILE="/etc/systemd/system/${SSH_SERVICE}.d/override.conf"
    OVERRIDE_FILE="/etc/systemd/system/${SSH_SERVICE}.d/${OVERRIDE_NAME}"
    WATCHER_SERVICE_FILE="/etc/systemd/system/${WATCHER_SERVICE}"

    if systemctl is-enabled --quiet "${WATCHER_SERVICE}" 2>/dev/null; then
        WATCHER_WAS_ENABLED=1
    fi

    if systemctl is-active --quiet "${WATCHER_SERVICE}" 2>/dev/null; then
        WATCHER_WAS_ACTIVE=1
    fi

    if [[ -f "${LEGACY_OVERRIDE_FILE}" ]] &&
       is_legacy_ssh_override "${LEGACY_OVERRIDE_FILE}"; then
        if ! prepare_target "${LEGACY_OVERRIDE_FILE}"; then
            rollback_install
            return 1
        fi
        if ! rm -f -- "${LEGACY_OVERRIDE_FILE}"; then
            echo "[ERROR] Failed to remove the legacy project override."
            rollback_install
            return 1
        fi
    fi

    if ! prepare_target "${WATCHER_PATH}" ||
       ! prepare_target "${WATCHER_SERVICE_FILE}" ||
       ! prepare_target "${OVERRIDE_FILE}"; then
        rollback_install
        return 1
    fi

    # --------------------------------------------------------
    # Create files
    # --------------------------------------------------------

    if ! create_watcher_script ||
       ! create_watcher_service ||
       ! create_ssh_override; then
        echo "[ERROR] Failed to write project files."
        rollback_install
        return 1
    fi

    # --------------------------------------------------------
    # Reload systemd
    # --------------------------------------------------------

    echo
    echo "[INFO] Reloading systemd..."

    if ! systemctl daemon-reload; then
        echo "[ERROR] systemd daemon-reload failed."
        rollback_install
        return 1
    fi

    # --------------------------------------------------------
    # Enable watcher
    # --------------------------------------------------------

    echo "[INFO] Enabling watcher service..."

    if ! systemctl enable "${WATCHER_SERVICE}"; then
        echo "[ERROR] Failed to enable watcher service."
        rollback_install
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

        rollback_install
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
        rollback_install
        return 1
    fi

    finish_install

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

    if [[ -e "${WATCHER_SERVICE_FILE}" ]]; then
        if remove_managed_file "${WATCHER_SERVICE_FILE}"; then
            echo "[INFO] Removing:"
            echo "       ${WATCHER_SERVICE_FILE}"
            REMOVED=1
        fi
    fi

    # --------------------------------------------------------
    # Remove watcher script
    # --------------------------------------------------------

    if [[ -e "${WATCHER_PATH}" ]]; then
        if remove_managed_file "${WATCHER_PATH}"; then
            echo "[INFO] Removing:"
            echo "       ${WATCHER_PATH}"
            REMOVED=1
        fi
    fi

    # --------------------------------------------------------
    # Remove SSH override
    # --------------------------------------------------------

    for SERVICE in ssh.service sshd.service; do

        OVERRIDE_DIR="/etc/systemd/system/${SERVICE}.d"
        for OVERRIDE_FILE in \
            "${OVERRIDE_DIR}/${OVERRIDE_NAME}" \
            "${OVERRIDE_DIR}/override.conf"; do

            if [[ -e "${OVERRIDE_FILE}" ]]; then
                if remove_managed_file "${OVERRIDE_FILE}"; then
                    echo "[INFO] Removing:"
                    echo "       ${OVERRIDE_FILE}"
                    REMOVED=1
                fi
            fi
        done

        if [[ -d "${OVERRIDE_DIR}" ]]; then
            rmdir "${OVERRIDE_DIR}" 2>/dev/null || true
        fi

    done

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
# Command-line and menu entry points
# ------------------------------------------------------------

usage() {
    echo "Usage: $0 {install|uninstall}"
    echo
    echo "Without an argument, an interactive menu is shown only on a terminal."
}

run_menu() {
    local CHOICE

    while true; do
        echo
        echo "=============================================="
        echo " SSH Auto-Restart for Tailscale / VPN IP"
        echo " Version 2.1"
        echo "=============================================="
        echo
        echo "  1) Install"
        echo "  2) Uninstall"
        echo "  3) Exit"
        echo

        if ! read -r -p "Please select [1-3]: " CHOICE; then
            echo
            echo "[INFO] No interactive input available. Exiting."
            return 0
        fi

        case "${CHOICE}" in
            1)
                if ! install_ssh_policy; then
                    echo
                    echo "[ERROR] Installation failed."
                    echo
                    return 1
                fi
                ;;
            2)
                uninstall_ssh_policy
                ;;
            3)
                echo
                echo "[INFO] Exiting."
                echo
                return 0
                ;;
            *)
                echo
                echo "[ERROR] Invalid selection."
                echo
                ;;
        esac
    done
}

case "${1:-}" in
    install)
        install_ssh_policy
        ;;
    uninstall)
        uninstall_ssh_policy
        ;;
    "")
        if [[ ! -t 0 ]]; then
            echo "[ERROR] A command is required when stdin is not interactive."
            usage
            exit 2
        fi
        run_menu
        ;;
    *)
        usage
        exit 2
        ;;
esac
