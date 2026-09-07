## Quick Install

Run the following command on your VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash
```

The script will display an interactive menu:

```text
==============================================
 SSH Auto-Restart for Tailscale / VPN IP
==============================================

  1) Install
  2) Uninstall
  3) Exit

Please select [1-3]:
```

### 1) Install

Installs the `systemd` SSH auto-restart policy.

If Tailscale is detected, SSH will also be configured to start after `tailscaled.service`.

### 2) Uninstall

Removes the SSH auto-restart configuration created by this project and reloads `systemd`.

The uninstall operation does **not** remove:

* OpenSSH
* Tailscale
* SSH keys
* `/etc/ssh/sshd_config`
* Other SSH configuration

### 3) Exit

Exits the installer without making changes.

> **Important:** The command above is a normal shell command. Do not replace the URL with Markdown link syntax such as `[URL](URL)`. Use GitHub's **Copy code** button to copy the command directly.
