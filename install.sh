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
INSTALL_IN_PROGRESS=0
LOCK_FILE="/run/ssh-tailscale-autorestart.lock"

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
# Prevent concurrent runs
# ------------------------------------------------------------

if ! command -v flock >/dev/null 2>&1; then
    echo "[ERROR] flock is required to prevent concurrent configuration changes."
    echo "        Install the util-linux package, then run this script again."
    exit 1
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "[ERROR] Another ${PROJECT_NAME} process is already running."
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

    [[ -f "${FILE}" ]] || return 1

    if ! grep -Fqx "After=tailscaled.service" "${FILE}" &&
        ! grep -Fqx "Restart=always" "${FILE}"; then
        return 1
    fi

    if ! grep -Fq "tailscaled.service" "${FILE}" ||
        ! grep -Fq "RestartSec=" "${FILE}"; then
        return 1
    fi

    # Only accept the small set of directives produced by older versions.
    # This avoids deleting a user's unrelated override.conf by accident.
    if grep -Ev '^[[:space:]]*(#.*)?$|^[[:space:]]*\[(Unit|Service)\][[:space:]]*$|^[[:space:]]*(After=tailscaled\.service|Wants=tailscaled\.service|Restart=(on-failure|always)|RestartSec=(3s|5s)|StartLimitInterval(Sec)?=0|RestartPreventExitStatus=)[[:space:]]*$' "${FILE}" |
        grep -q .; then
        return 1
    fi

    return 0
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
    INSTALL_IN_PROGRESS=0
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
    INSTALL_IN_PROGRESS=0
}

cleanup_install_on_exit() {
    local EXIT_STATUS="$?"

    if [[ "${INSTALL_IN_PROGRESS}" -eq 1 ]]; then
        rollback_install >/dev/null 2>&1 || true
    fi

    exit "${EXIT_STATUS}"
}

trap cleanup_install_on_exit EXIT

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

is_valid_ipv4() {
    local IP="$1"
    local OCTET
    local OCTETS

    if ! [[ "${IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        return 1
    fi

    IFS='.' read -r -a OCTETS <<< "${IP}"
    for OCTET in "${OCTETS[@]}"; do
        if ((10#${OCTET} > 255)); then
            return 1
        fi
    done

    return 0
}

validate_tailscale_listen_only() {
    local TS_IP="$1"
    local SSHD_BIN
    local SSHD_OUTPUT
    local ADDRESS
    local FOUND=0

    if ! SSHD_BIN="$(detect_sshd_binary)"; then
        echo "[ERROR] sshd binary was not found."
        return 1
    fi

    if ! SSHD_OUTPUT="$("${SSHD_BIN}" -T 2>/dev/null)"; then
        echo "[ERROR] Failed to inspect the effective SSH configuration."
        return 1
    fi

    while IFS= read -r ADDRESS; do
        [[ -z "${ADDRESS}" ]] && continue
        FOUND=1

        if [[ "${ADDRESS}" != "${TS_IP}" &&
            "${ADDRESS}" != "${TS_IP}:"* ]]; then
            echo "[ERROR] SSH still has a non-Tailscale listen address: ${ADDRESS}"
            return 1
        fi
    done < <(printf '%s\n' "${SSHD_OUTPUT}" | awk '$1 == "listenaddress" { print $2 }')

    if [[ "${FOUND}" -eq 0 ]]; then
        echo "[ERROR] No effective SSH listen address was found."
        return 1
    fi
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
RETRY_DELAY="${RETRY_DELAY:-10}"

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
            else
                sleep "${RETRY_DELAY}"
            fi

        elif [[ "${CURRENT_IP}" != "${PREVIOUS_IP}" ]]; then

            log "Tailscale IPv4 changed:"
            log "  old: ${PREVIOUS_IP}"
            log "  new: ${CURRENT_IP}"

            if restart_ssh; then
                PREVIOUS_IP="${CURRENT_IP}"
            else
                sleep "${RETRY_DELAY}"
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
    INSTALL_IN_PROGRESS=1

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
    local REMOVED=0
    local REMOVAL_FAILED=0
    local WATCHER_CAN_REMOVE=0
    local WATCHER_SERVICE_FILE="/etc/systemd/system/${WATCHER_SERVICE}"

    # --------------------------------------------------------
    # Stop watcher
    # --------------------------------------------------------

    if [[ -e "${WATCHER_SERVICE_FILE}" ]]; then
        if is_managed_file "${WATCHER_SERVICE_FILE}" ||
            is_legacy_watcher_service "${WATCHER_SERVICE_FILE}"; then
            WATCHER_CAN_REMOVE=1
        else
            echo "[WARNING] Preserving unmanaged file: ${WATCHER_SERVICE_FILE}"
            REMOVAL_FAILED=1
        fi
    elif systemctl cat "${WATCHER_SERVICE}" >/dev/null 2>&1; then
        WATCHER_CAN_REMOVE=1
    fi

    if [[ "${WATCHER_CAN_REMOVE}" -eq 1 ]]; then

        if ! systemctl stop "${WATCHER_SERVICE}" >/dev/null 2>&1; then
            echo "[ERROR] Failed to stop ${WATCHER_SERVICE}."
            REMOVAL_FAILED=1
        fi

        if ! systemctl disable "${WATCHER_SERVICE}" >/dev/null 2>&1; then
            echo "[ERROR] Failed to disable ${WATCHER_SERVICE}."
            REMOVAL_FAILED=1
        fi

    fi

    # --------------------------------------------------------
    # Remove watcher service
    # --------------------------------------------------------

    if [[ -e "${WATCHER_SERVICE_FILE}" ]]; then
        if remove_managed_file "${WATCHER_SERVICE_FILE}"; then
            REMOVED=1
        else
            REMOVAL_FAILED=1
        fi
    fi

    # --------------------------------------------------------
    # Remove watcher script
    # --------------------------------------------------------

    if [[ -e "${WATCHER_PATH}" ]]; then
        if remove_managed_file "${WATCHER_PATH}"; then
            REMOVED=1
        else
            REMOVAL_FAILED=1
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
                else
                    REMOVAL_FAILED=1
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

    if [[ "${REMOVAL_FAILED}" -eq 1 ]]; then
        echo "[ERROR] Project files were not fully removed."
        echo "[ERROR] Tailscale uninstall was not attempted."
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

    if systemctl cat tailscaled.service >/dev/null 2>&1 &&
        ! systemctl is-active --quiet tailscaled.service 2>/dev/null; then
        if ! systemctl start tailscaled.service >/dev/null 2>&1; then
            echo
            echo "[ERROR] Failed to start tailscaled.service."
            return 1
        fi
    fi

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
    if ! is_valid_ipv4 "${TS_IP}"; then
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
        if ! cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"; then
            echo "[ERROR] Failed to restore the original SSH configuration."
        fi
        return 1
    fi

    if ! validate_tailscale_listen_only "${TS_IP}"; then
        echo
        echo "[ERROR] SSH is not restricted to the requested Tailscale IPv4."
        echo "[ERROR] This may be caused by another ListenAddress in an included file."
        if ! cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"; then
            echo "[ERROR] Failed to restore the original SSH configuration."
        fi
        return 1
    fi

    SSH_SERVICE="$(detect_ssh_service)" || SSH_SERVICE="ssh.service"

    if ! systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
        echo
        echo "[ERROR] SSH restart failed. Restoring original config."
        if ! cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"; then
            echo "[ERROR] Failed to restore the original SSH configuration."
        fi
        systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1 || true
        return 1
    fi

    echo
    echo "Done. SSH now listens ONLY on Tailscale IP: ${TS_IP}"
    echo "To undo, choose option 2 in the menu or run: $0 restore-ssh-listen"
    echo
}

# ------------------------------------------------------------
# Restore SSH to default listen-on-all-interfaces
# ------------------------------------------------------------

restore_ssh_listen() {
    local CURRENT_CONFIG_BACKUP
    local HAS_PROJECT_BACKUP=0
    local CONFIG_CHANGED=0

    if [[ ! -f "${SSHD_CONFIG}" ]]; then
        echo "[ERROR] SSH configuration file was not found: ${SSHD_CONFIG}"
        return 1
    fi

    if ! CURRENT_CONFIG_BACKUP="$(mktemp "/tmp/${PROJECT_NAME}.restore.XXXXXX")"; then
        echo "[ERROR] Failed to create a temporary SSH configuration backup."
        return 1
    fi

    if ! cp -a -- "${SSHD_CONFIG}" "${CURRENT_CONFIG_BACKUP}"; then
        rm -f -- "${CURRENT_CONFIG_BACKUP}"
        echo "[ERROR] Failed to back up the current SSH configuration."
        return 1
    fi

    # Prefer the exact pre-install backup. This avoids accidentally
    # re-enabling ListenAddress directives that the user had commented out.
    if [[ -f "${SSHD_CONFIG_BACKUP}" ]]; then
        if ! cp -a -- "${SSHD_CONFIG_BACKUP}" "${SSHD_CONFIG}"; then
            cp -a -- "${CURRENT_CONFIG_BACKUP}" "${SSHD_CONFIG}" >/dev/null 2>&1 || true
            rm -f -- "${CURRENT_CONFIG_BACKUP}"
            echo "[ERROR] Failed to restore the original SSH configuration."
            return 1
        fi
        HAS_PROJECT_BACKUP=1
        CONFIG_CHANGED=1
        echo "Restored ${SSHD_CONFIG} from the project backup."

    else
        if grep -Fq "${LISTEN_ADDRESS_MARKER}" "${SSHD_CONFIG}" 2>/dev/null; then
            if ! sed -i "/^${LISTEN_ADDRESS_MARKER//\//\\/}$/,+1d" "${SSHD_CONFIG}"; then
                cp -a -- "${CURRENT_CONFIG_BACKUP}" "${SSHD_CONFIG}" >/dev/null 2>&1 || true
                rm -f -- "${CURRENT_CONFIG_BACKUP}"
                echo "[ERROR] Failed to remove the managed ListenAddress block."
                return 1
            fi
            CONFIG_CHANGED=1
            echo "Removed the managed ListenAddress block from ${SSHD_CONFIG}."
        else
            echo "[INFO] No managed ListenAddress or project backup was found."
        fi
    fi

    if [[ "${CONFIG_CHANGED}" -eq 0 ]]; then
        rm -f -- "${CURRENT_CONFIG_BACKUP}"
        return 0
    fi

    if ! validate_sshd_config; then
        echo
        echo "[ERROR] sshd_config validation failed after restore."
        echo "        Please check ${SSHD_CONFIG} manually."
        cp -a -- "${CURRENT_CONFIG_BACKUP}" "${SSHD_CONFIG}" >/dev/null 2>&1 || true
        rm -f -- "${CURRENT_CONFIG_BACKUP}"
        return 1
    fi

    SSH_SERVICE="$(detect_ssh_service)" || SSH_SERVICE="ssh.service"

    if ! systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1; then
        echo "[WARNING] SSH restart failed."
        echo "          Check: systemctl status ${SSH_SERVICE}"
        cp -a -- "${CURRENT_CONFIG_BACKUP}" "${SSHD_CONFIG}" >/dev/null 2>&1 || true
        systemctl restart "${SSH_SERVICE}" >/dev/null 2>&1 || true
        rm -f -- "${CURRENT_CONFIG_BACKUP}"
        return 1
    fi

    if [[ "${HAS_PROJECT_BACKUP}" -eq 1 ]]; then
        rm -f -- "${SSHD_CONFIG_BACKUP}"
    fi

    rm -f -- "${CURRENT_CONFIG_BACKUP}"

    echo
    echo "Done. SSH is now restored to default (listening on all interfaces)."
    echo
}

# ------------------------------------------------------------
# 1) Set SSH to Tailscale IPv4 only (Auto-runs autorestart setup)
# ------------------------------------------------------------

set_tailscale_only_ssh() {
    echo "============================================================"
    echo " [1/2] 正在设置 SSH 仅允许 Tailscale IPv4 登录..."
    echo "============================================================"

    if ! restrict_ssh_to_tailscale; then
        echo
        echo "[ERROR] 设置 Tailscale IP 绑定失败。"
        return 1
    fi

    echo
    echo "============================================================"
    echo " [2/2] 正在配置 Tailscale 守护与 SSH 自动重启服务..."
    echo "============================================================"

    if ! install_ssh_policy; then
        echo
        echo "[ERROR] Tailscale 自启动监控服务安装失败，正在恢复原 SSH 配置。"
        if ! restore_ssh_listen; then
            echo "[ERROR] SSH 配置恢复失败，请立即通过 VPS 控制台检查 ${SSHD_CONFIG}。"
        fi
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

    if ! restore_ssh_listen; then
        echo "[ERROR] SSH 恢复失败。"
        return 1
    fi

    echo "============================================================"
    echo "[成功] 已恢复公网 IP 登录状态。"
    echo "============================================================"
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
    local CONFIRMATION
    local UNINSTALL_FAILED=0
    local PACKAGE_MANAGER_FOUND=0

    echo "============================================================"
    echo " 彻底删除 Tailscale"
    echo "============================================================"

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

    echo "1. 清理 Tailscale 自启动监控服务..."
    if ! uninstall_ssh_policy; then
        echo "[ERROR] Tailscale 自启动监控服务未能完整移除。"
        echo "[ERROR] 为避免残留 watcher 调用已卸载的程序，已中止 Tailscale 卸载。"
        return 1
    fi

    echo "2. 停止并禁用 tailscaled 服务..."
    if systemctl is-active --quiet tailscaled.service 2>/dev/null &&
        ! systemctl stop tailscaled.service >/dev/null 2>&1; then
        echo "[ERROR] Failed to stop tailscaled.service."
        UNINSTALL_FAILED=1
    fi

    if systemctl is-enabled --quiet tailscaled.service 2>/dev/null &&
        ! systemctl disable tailscaled.service >/dev/null 2>&1; then
        echo "[ERROR] Failed to disable tailscaled.service."
        UNINSTALL_FAILED=1
    fi

    if [[ "${UNINSTALL_FAILED}" -eq 1 ]]; then
        return 1
    fi

    echo "3. 卸载 Tailscale 软件包..."
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER_FOUND=1
        if ! apt-get purge -y tailscale tailscale-archive-keyring >/dev/null 2>&1 &&
            ! apt-get remove --purge -y tailscale >/dev/null 2>&1; then
            echo "[ERROR] Failed to remove the Tailscale package with apt."
            UNINSTALL_FAILED=1
        fi
        rm -f /etc/apt/sources.list.d/tailscale.list \
            /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null || true
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER_FOUND=1
        if ! dnf remove -y tailscale >/dev/null 2>&1; then
            echo "[ERROR] Failed to remove the Tailscale package with dnf."
            UNINSTALL_FAILED=1
        fi
        rm -f /etc/yum.repos.d/tailscale.repo 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER_FOUND=1
        if ! yum remove -y tailscale >/dev/null 2>&1; then
            echo "[ERROR] Failed to remove the Tailscale package with yum."
            UNINSTALL_FAILED=1
        fi
        rm -f /etc/yum.repos.d/tailscale.repo 2>/dev/null || true
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER_FOUND=1
        if ! pacman -Rns --noconfirm tailscale >/dev/null 2>&1; then
            echo "[ERROR] Failed to remove the Tailscale package with pacman."
            UNINSTALL_FAILED=1
        fi
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER_FOUND=1
        if ! apk del tailscale >/dev/null 2>&1; then
            echo "[ERROR] Failed to remove the Tailscale package with apk."
            UNINSTALL_FAILED=1
        fi
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER_FOUND=1
        if ! zypper remove -y tailscale >/dev/null 2>&1; then
            echo "[ERROR] Failed to remove the Tailscale package with zypper."
            UNINSTALL_FAILED=1
        fi
    else
        echo "[ERROR] No supported package manager was found."
        UNINSTALL_FAILED=1
    fi

    if [[ "${PACKAGE_MANAGER_FOUND}" -eq 0 || "${UNINSTALL_FAILED}" -eq 1 ]]; then
        echo "[ERROR] Tailscale was not completely removed."
        return 1
    fi

    echo "4. 清理 Tailscale 配置与残留目录..."
    rm -rf /var/lib/tailscale /var/run/tailscale /etc/tailscale 2>/dev/null || true

    if ! systemctl daemon-reload >/dev/null 2>&1; then
        echo "[ERROR] systemd daemon-reload failed."
        return 1
    fi

    if command -v tailscale >/dev/null 2>&1 ||
        [[ -e "/usr/sbin/tailscaled" ]]; then
        echo "[ERROR] Tailscale binaries are still present after package removal."
        echo "[ERROR] They were not deleted automatically; inspect the installation manually."
        return 1
    fi

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

