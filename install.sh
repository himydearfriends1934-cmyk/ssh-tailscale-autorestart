#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# SSH Auto-Restart for Tailscale / VPN IP Binding
# Version: 2.2
#
# Features:
#   - Detect ssh.service / sshd.service
#   - Detect tailscaled.service
#   - Watch actual Tailscale IPv4 address
#   - Restart SSH when Tailscale IP appears / changes
#   - Restart SSH when the service itself fails
#   - Validate sshd configuration before restart
#   - Clean install / uninstall
#   - Restrict SSH to Tailscale IP only (ListenAddress)
#   - Restore SSH to default listen-on-all-interfaces
#
# Project:
# https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart
# ============================================================

PROJECT_NAME="ssh-tailscale-autorestart"
WATCHER_PATH="/usr/local/sbin/tailscale-ssh-watch"
WATCHER_SERVICE="tailscale-ssh-watch.service"
OVERRIDE_NAME="90-tailscale-ssh-autorestart.conf"
MANAGED_HEADER="# Managed by ${PROJECT_NAME}"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_BACKUP="/etc/ssh/sshd_config.${PROJECT_NAME}.bak"
LISTEN_ADDRESS_MARKER="# ListenAddress managed by ${PROJECT_NAME}"

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
        if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then
            echo "${SERVICE}"
            return 0
        fi
    done

    for SERVICE in ssh.service sshd.service; do
        if systemctl is-enabled --quiet "${SERVICE}" 2>/dev/null; then
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

    if "${SSHD_BIN}" -t; then
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

    if ! TAILSCALE_COMMAND="$(detect_tailscale_command)"; then
        echo
        echo "[ERROR] tailscale command was not found."
        echo
        echo "Install Tailscale first, then run this installer again."
        echo
        return 1
    fi

    # --------------------------------------------------------
    # Check Tailscale service
    # --------------------------------------------------------

    if ! systemctl is-active --quiet tailscaled.service 2>/dev/null; then
        if ! systemctl start tailscaled.service >/dev/null 2>&1; then
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

    if ! systemctl daemon-reload >/dev/null 2>&1; then
        echo "[ERROR] systemd daemon-reload failed."
        rollback_install
        return 1
    fi

    # --------------------------------------------------------
    # Enable watcher
    # --------------------------------------------------------

    if ! systemctl enable "${WATCHER_SERVICE}" >/dev/null 2>&1; then
        echo "[ERROR] Failed to enable watcher service."
        rollback_install
        return 1
    fi

    # --------------------------------------------------------
    # Restart SSH
    # --------------------------------------------------------

    if ! systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
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

    if ! systemctl restart "${WATCHER_SERVICE}" >/dev/null 2>&1; then
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

    echo "Installation completed."
}

# ------------------------------------------------------------
# Uninstall
# ------------------------------------------------------------

uninstall_ssh_policy() {

    REMOVED=0

    # --------------------------------------------------------
    # Stop watcher
    # --------------------------------------------------------

    if systemctl list-unit-files "${WATCHER_SERVICE}" >/dev/null 2>&1; then

        systemctl stop "${WATCHER_SERVICE}" >/dev/null 2>&1 || true

        systemctl disable "${WATCHER_SERVICE}" >/dev/null 2>&1 || true

    fi

    # --------------------------------------------------------
    # Remove watcher service
    # --------------------------------------------------------

    WATCHER_SERVICE_FILE="/etc/systemd/system/${WATCHER_SERVICE}"

    if [[ -e "${WATCHER_SERVICE_FILE}" ]]; then
        if remove_managed_file "${WATCHER_SERVICE_FILE}"; then
            REMOVED=1
        fi
    fi

    # --------------------------------------------------------
    # Remove watcher script
    # --------------------------------------------------------

    if [[ -e "${WATCHER_PATH}" ]]; then
        if remove_managed_file "${WATCHER_PATH}"; then
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

    if ! systemctl daemon-reload >/dev/null 2>&1; then
        echo "[ERROR] systemd daemon-reload failed."
        return 1
    fi

    # --------------------------------------------------------
    # Restart SSH without project override
    # --------------------------------------------------------

    if SSH_SERVICE="$(detect_ssh_service)"; then

        if validate_sshd_config; then

            if ! systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
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

    if [[ "${REMOVED}" -eq 1 ]]; then
        echo "Configuration removed. SSH restored."

    else
        echo "Nothing to uninstall."

    fi
}

# ------------------------------------------------------------
# Restrict SSH to Tailscale IP only
# ------------------------------------------------------------

restrict_ssh_to_tailscale() {

    # --------------------------------------------------------
    # Need Tailscale command
    # --------------------------------------------------------

    if ! TAILSCALE_COMMAND="$(detect_tailscale_command)"; then
        echo
        echo "[ERROR] tailscale command was not found."
        echo
        echo "Install Tailscale first, then run this option again."
        echo
        return 1
    fi

    # --------------------------------------------------------
    # Get current Tailscale IPv4
    # --------------------------------------------------------

    local TS_IP
    TS_IP="$("${TAILSCALE_COMMAND}" ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')" || true

    if [[ -z "${TS_IP}" ]]; then
        echo
        echo "[ERROR] Cannot get Tailscale IPv4 address."
        echo "        Make sure Tailscale is running and connected."
        echo
        return 1
    fi

    # Validate IP format
    if ! [[ "${TS_IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "[ERROR] Unexpected IP format: ${TS_IP}"
        return 1
    fi

    echo "Tailscale IPv4: ${TS_IP}"

    # --------------------------------------------------------
    # Backup sshd_config if not already done
    # --------------------------------------------------------

    if [[ -f "${SSHD_CONFIG_BACKUP}" ]]; then
        echo "[INFO] Backup already exists: ${SSHD_CONFIG_BACKUP}"
        echo "[INFO] Skipping backup to avoid overwriting original."
    else
        if ! cp -a -- "${SSHD_CONFIG}" "${SSHD_CONFIG_BACKUP}"; then
            echo "[ERROR] Failed to back up ${SSHD_CONFIG}."
            return 1
        fi
        echo "Backup saved: ${SSHD_CONFIG_BACKUP}"
    fi

    # --------------------------------------------------------
    # Remove any previously managed ListenAddress lines
    # --------------------------------------------------------

    # Remove the marker line and the ListenAddress line directly after it
    sed -i "/^${LISTEN_ADDRESS_MARKER//\//\\/}$/,+1d" "${SSHD_CONFIG}" 2>/dev/null || true

    # Also remove any leftover bare managed ListenAddress lines
    sed -i "/^ListenAddress.*# ${PROJECT_NAME}$/d" "${SSHD_CONFIG}" 2>/dev/null || true

    # --------------------------------------------------------
    # Comment out any existing ListenAddress directives
    # (so they don't conflict)
    # --------------------------------------------------------

    sed -i "s/^ListenAddress /#ListenAddress /g" "${SSHD_CONFIG}"

    # --------------------------------------------------------
    # Append managed ListenAddress block
    # --------------------------------------------------------

    printf '\n%s\nListenAddress %s\n' \
        "${LISTEN_ADDRESS_MARKER}" \
        "${TS_IP}" \
        >> "${SSHD_CONFIG}"

    # --------------------------------------------------------
    # Validate and restart SSH
    # --------------------------------------------------------

    if ! validate_sshd_config; then
        echo
        echo "[ERROR] sshd_config validation failed. Restoring original."
        cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"
        return 1
    fi

    SSH_SERVICE="$(detect_ssh_service)" || SSH_SERVICE="ssh.service"

    if ! systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
        echo
        echo "[ERROR] SSH restart failed. Restoring original config."
        cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"
        systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1 || true
        return 1
    fi

    echo
    echo "Done. SSH now listens ONLY on Tailscale IP: ${TS_IP}"
    echo "To undo, choose option 4 in the menu or run: $0 restore-ssh-listen"
    echo
}

# ------------------------------------------------------------
# Restore SSH to default listen-on-all-interfaces
# ------------------------------------------------------------

restore_ssh_listen() {

    # --------------------------------------------------------
    # Remove managed ListenAddress block from sshd_config
    # --------------------------------------------------------

    if grep -Fq "${LISTEN_ADDRESS_MARKER}" "${SSHD_CONFIG}" 2>/dev/null; then

        # Remove the marker line and the ListenAddress line after it
        sed -i "/^${LISTEN_ADDRESS_MARKER//\//\\/}$/,+1d" "${SSHD_CONFIG}"

        echo "Removed managed ListenAddress from ${SSHD_CONFIG}."

    else
        echo "[INFO] No managed ListenAddress found in ${SSHD_CONFIG}."
    fi

    # Re-enable any previously commented-out ListenAddress lines
    sed -i "s/^#ListenAddress /ListenAddress /g" "${SSHD_CONFIG}"

    # --------------------------------------------------------
    # Restore from backup if available
    # --------------------------------------------------------

    if [[ -f "${SSHD_CONFIG_BACKUP}" ]]; then
        local CONFIRMATION
        echo
        echo "A backup of the original sshd_config was found:"
        echo "  ${SSHD_CONFIG_BACKUP}"
        if ! read -r -p "Restore from backup instead? [y/N]: " CONFIRMATION; then
            CONFIRMATION="n"
        fi
        case "${CONFIRMATION}" in
            y|Y|yes|YES)
                cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"
                rm -f -- "${SSHD_CONFIG_BACKUP}"
                echo "Original sshd_config restored from backup."
                ;;
            *)
                rm -f -- "${SSHD_CONFIG_BACKUP}"
                echo "Backup deleted. Kept the inline-edited config."
                ;;
        esac
    fi

    # --------------------------------------------------------
    # Validate and restart SSH
    # --------------------------------------------------------

    if ! validate_sshd_config; then
        echo
        echo "[ERROR] sshd_config validation failed after restore."
        echo "        Please check ${SSHD_CONFIG} manually."
        return 1
    fi

    SSH_SERVICE="$(detect_ssh_service)" || SSH_SERVICE="ssh.service"

    if ! systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
        echo "[WARNING] SSH restart failed."
        echo "          Check: systemctl status ${SSH_SERVICE}"
        return 1
    fi

    echo
    echo "Done. SSH is now restored to default (listening on all interfaces)."
    echo
}

# ------------------------------------------------------------
# 1) Set SSH to Tailscale IPv4 only (Auto-runs autorestart setup)
# ------------------------------------------------------------

set_tailscale_only_ssh() {
    echo "============================================================"
    echo " [1/2] 正在配置 Tailscale 守护与 SSH 自动重启服务..."
    echo "============================================================"

    if ! install_ssh_policy; then
        echo
        echo "[ERROR] Tailscale 自启动监控服务安装失败，已中止配置。"
        return 1
    fi

    echo
    echo "============================================================"
    echo " [2/2] 正在设置 SSH 仅允许 Tailscale IPv4 登录..."
    echo "============================================================"

    if ! restrict_ssh_to_tailscale; then
        echo
        echo "[ERROR] 设置 Tailscale IP 绑定失败。"
        return 1
    fi

    echo "============================================================"
    echo "[成功] 已成功设置 SSH 仅 Tailscale IPv4 登录！"
    echo "[成功] Tailscale 自启动守护已联动生效。"
    echo "============================================================"
}

# ------------------------------------------------------------
# 2) Restore original network state (Public IP login)
# ------------------------------------------------------------

restore_original_network_state() {
    echo "============================================================"
    echo " 正在恢复到网络原始状态（恢复公网 IP 登录）..."
    echo "============================================================"

    if restore_ssh_listen; then
        echo "============================================================"
        echo "[成功] 已恢复公网 IP 登录状态。"
        echo "============================================================"
    fi
}

# ------------------------------------------------------------
# 3) Remove Tailscale autostart
# ------------------------------------------------------------

remove_tailscale_autostart() {
    local CONFIRMATION

    if [[ -t 0 && -t 1 ]]; then
        if ! read -r -p "确定要删除 Tailscale SSH 自启动监控服务吗？[y/N]: " CONFIRMATION; then
            echo "已取消。"
            return 0
        fi

        case "${CONFIRMATION}" in
            y|Y|yes|YES)
                ;;
            *)
                echo "已取消。"
                return 0
                ;;
        esac
    fi

    uninstall_ssh_policy
}

# ------------------------------------------------------------
# 4) Completely uninstall Tailscale
# ------------------------------------------------------------

uninstall_tailscale_complete() {
    echo "============================================================"
    echo " 彻底删除 Tailscale"
    echo "============================================================"

    # 安全防失联检查：如果当前处于仅 Tailscale IP 登录，自动先恢复公网登录
    if grep -Fq "${LISTEN_ADDRESS_MARKER}" "${SSHD_CONFIG}" 2>/dev/null; then
        echo
        echo "[警告] 检测到当前 SSH 正处于【仅 Tailscale IP 登录】状态！"
        echo "[警告] 若直接删除 Tailscale 将导致服务器彻底失联！"
        echo "[操作] 正在自动为你先恢复 SSH 原始公网登录状态..."
        echo
        if ! restore_ssh_listen; then
            echo "[ERROR] 恢复公网登录失败，为安全起见，已中止卸载 Tailscale。"
            return 1
        fi
        echo "[提示] 公网 IP 登录已安全恢复。"
    fi

    local CONFIRMATION
    if [[ -t 0 && -t 1 ]]; then
        if ! read -r -p "警告：即将彻底卸载 Tailscale 软件及配置数据，确定继续吗？[y/N]: " CONFIRMATION; then
            echo "已取消。"
            return 0
        fi

        case "${CONFIRMATION}" in
            y|Y|yes|YES)
                ;;
            *)
                echo "已取消。"
                return 0
                ;;
        esac
    fi

    echo "1. 清理 Tailscale 自启动监控服务..."
    uninstall_ssh_policy >/dev/null 2>&1 || true

    echo "2. 停止并禁用 tailscaled 服务..."
    systemctl stop tailscaled.service >/dev/null 2>&1 || true
    systemctl disable tailscaled.service >/dev/null 2>&1 || true

    echo "3. 卸载 Tailscale 软件包..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get purge -y tailscale tailscale-archive-keyring >/dev/null 2>&1 || apt-get remove --purge -y tailscale >/dev/null 2>&1 || true
        rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y tailscale >/dev/null 2>&1 || true
        rm -f /etc/yum.repos.d/tailscale.repo 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y tailscale >/dev/null 2>&1 || true
        rm -f /etc/yum.repos.d/tailscale.repo 2>/dev/null || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Rns --noconfirm tailscale >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk del tailscale >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper remove -y tailscale >/dev/null 2>&1 || true
    fi

    echo "4. 清理 Tailscale 配置与残留目录..."
    rm -rf /var/lib/tailscale /var/run/tailscale /etc/tailscale 2>/dev/null || true
    rm -f /usr/bin/tailscale /usr/sbin/tailscaled 2>/dev/null || true

    systemctl daemon-reload >/dev/null 2>&1 || true

    echo
    echo "============================================================"
    echo "[成功] Tailscale 及其自启动服务已完全删除。"
    echo "============================================================"
}

# ------------------------------------------------------------
# Command-line and menu entry points
# ------------------------------------------------------------

usage() {
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  1 | set-tailscale-ssh      设置仅 Tailscale IPv4 SSH (自动联动自启动守护)"
    echo "  2 | restore-network        恢复到网络原来的状态 (恢复公网 IP 登录)"
    echo "  3 | remove-autostart       删除 Tailscale 自启动"
    echo "  4 | uninstall-tailscale    删除 Tailscale 软件及配置"
    echo "  install                    兼容别名：同选项 1"
    echo "  uninstall                  兼容别名：同选项 3"
    echo
    echo "不带参数时，在终端中启动交互菜单。"
}

run_menu() {
    local CHOICE

    echo "============================================================"
    echo " SSH & Tailscale 网络管理工具"
    echo "============================================================"
    echo "1) 设置仅 Tailscale IPv4 SSH (自动配置自启动)"
    echo "2) 恢复到网络原来的状态 (恢复公网 IP 登录)"
    echo "3) 删除 Tailscale 自启动"
    echo "4) 删除 Tailscale"
    echo "5) 退出脚本"
    echo "============================================================"

    if ! read -r -p "请选择 [1-5]: " CHOICE; then
        return 0
    fi

    case "${CHOICE}" in
        1)
            set_tailscale_only_ssh
            ;;
        2)
            restore_original_network_state
            ;;
        3)
            remove_tailscale_autostart
            ;;
        4)
            uninstall_tailscale_complete
            ;;
        5)
            echo "退出。"
            return 0
            ;;
        *)
            echo "[ERROR] 无效选项。"
            return 1
            ;;
    esac
}

case "${1:-}" in
    1|set-tailscale-ssh|restrict-ssh|install)
        set_tailscale_only_ssh
        ;;
    2|restore-network|restore|restore-ssh-listen)
        restore_original_network_state
        ;;
    3|remove-autostart|uninstall|uninstall-watcher)
        remove_tailscale_autostart
        ;;
    4|uninstall-tailscale)
        uninstall_tailscale_complete
        ;;
    "")
        if [[ ! -t 0 ]]; then
            echo "[ERROR] 当标准输入非交互时，必须指定命令参数。"
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

