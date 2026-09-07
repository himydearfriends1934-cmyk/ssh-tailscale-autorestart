# SSH Auto-Restart for Tailscale / VPN IP Binding

A lightweight `systemd` override configuration that automatically resolves SSH boot-time race conditions when `sshd` is configured to bind to a specific virtual network interface IP, such as Tailscale, WireGuard, or ZeroTier.

This is useful when the VPN interface or IP address is not available yet when the SSH service starts during system boot.

---

## Quick Install — One-Liner

Run the following command directly on your VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash
```

The command above can be copied directly using GitHub's **Copy code** button and pasted into your VPS terminal.

> **Important:**
> The URL inside the shell command must be a plain URL.
>
> Do **not** use Markdown link syntax such as:
>
> ```text
> [https://example.com/install.sh](https://example.com/install.sh)
> ```
>
> Markdown links are for displaying clickable links in README text. They must not be placed inside a shell command.

---

## Root User

If you are already logged in as `root`, use:

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | bash
```

---

## What Problem Does This Solve?

When SSH is configured with a specific virtual network IP:

```text
ListenAddress 100.x.x.x
```

the IP address may not exist yet during early system boot.

For example, the boot sequence may look like this:

```text
System Boot
    │
    ├── sshd starts
    │
    ├── Tailscale IP does not exist yet
    │
    ├── sshd fails to bind to the configured IP
    │
    ├── Tailscale starts
    │
    ├── Tailscale IP becomes available
    │
    └── sshd automatically restarts
```

Without an automatic restart mechanism, SSH may remain stopped even after the VPN interface becomes available.

This project uses a `systemd` override to make SSH retry automatically.

---

## Supported Use Cases

This configuration can be useful with virtual network interfaces and VPN services such as:

* Tailscale
* WireGuard
* ZeroTier
* Other VPN interfaces
* Other virtual network interfaces that become available after system boot

For example:

```text
ListenAddress 100.64.0.10
```

If `100.64.0.10` is a Tailscale IP and that address does not exist when `sshd` starts, SSH may fail to start.

---

## How It Works

The installation creates a `systemd` override for the SSH service.

The override typically contains:

```ini
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
Restart=always
RestartSec=3
```

### `After=tailscaled.service`

Starts SSH after the Tailscale service in the systemd startup ordering.

### `Wants=tailscaled.service`

Ensures that the Tailscale service is pulled in when SSH is started.

### `Restart=always`

Automatically attempts to restart SSH if the service exits or fails.

### `RestartSec=3`

Waits 3 seconds before attempting another restart.

This gives the VPN interface time to become available.

---

## Installation

### Option 1 — One-Line Installation

Recommended for quick installation:

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash
```

### Option 2 — Download and Review First

If you prefer to inspect the installation script before running it:

```bash
curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh
```

View the script:

```bash
cat /tmp/install.sh
```

Then execute it:

```bash
sudo bash /tmp/install.sh
```

---

## Check SSH Configuration

Before troubleshooting SSH startup problems, check the SSH configuration:

```bash
sudo sshd -t
```

If the command produces no output, the SSH configuration syntax is usually valid.

You can also check which addresses and ports SSH is currently listening on:

```bash
sudo ss -lntp | grep ssh
```

For example:

```text
LISTEN 0 128 100.64.0.10:22
```

This indicates that SSH is listening on the Tailscale IP.

---

## Check Tailscale

Check the Tailscale service:

```bash
sudo systemctl status tailscaled
```

Check the Tailscale IP address:

```bash
tailscale ip
```

You can also inspect network interfaces:

```bash
ip addr
```

---

## Check SSH Service

On Debian and Ubuntu, the SSH service is commonly named:

```bash
ssh.service
```

Check its status:

```bash
sudo systemctl status ssh
```

View the systemd configuration:

```bash
sudo systemctl cat ssh
```

On systems using `sshd.service`:

```bash
sudo systemctl status sshd
```

and:

```bash
sudo systemctl cat sshd
```

---

## Check the systemd Override

The override is normally located at:

```text
/etc/systemd/system/ssh.service.d/override.conf
```

View it with:

```bash
sudo cat /etc/systemd/system/ssh.service.d/override.conf
```

If your system uses `sshd.service`:

```text
/etc/systemd/system/sshd.service.d/override.conf
```

You can check it with:

```bash
sudo cat /etc/systemd/system/sshd.service.d/override.conf
```

---

## View SSH Boot Logs

To view SSH logs from the current boot:

```bash
sudo journalctl -u ssh -b --no-pager
```

For systems using `sshd`:

```bash
sudo journalctl -u sshd -b --no-pager
```

Look for errors such as:

```text
Cannot bind to port
```

or:

```text
Cannot bind any address
```

These errors commonly indicate that the configured `ListenAddress` was not available when SSH attempted to start.

---

## Manual Test

After installation, you can manually restart SSH:

```bash
sudo systemctl restart ssh
```

Then check:

```bash
sudo systemctl status ssh
```

For systems using `sshd`:

```bash
sudo systemctl restart sshd
sudo systemctl status sshd
```

---

## Troubleshooting

### GitHub Raw Cannot Be Reached

Test connectivity:

```bash
curl -I https://raw.githubusercontent.com
```

You can also test the installation script directly:

```bash
curl -v https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh
```

If the VPS cannot connect to `raw.githubusercontent.com`, the issue is likely related to network connectivity, DNS, firewall rules, or outbound filtering.

---

### SSH Service Name Is Different

Check the available SSH service:

```bash
systemctl list-unit-files | grep -E '^ssh(d)?\.service'
```

Typical results may include:

```text
ssh.service
```

or:

```text
sshd.service
```

Use the service name provided by your operating system.

---

### SSH Still Does Not Start

First validate the SSH configuration:

```bash
sudo sshd -t
```

Then check the service:

```bash
sudo systemctl status ssh
```

And view the boot logs:

```bash
sudo journalctl -u ssh -b --no-pager
```

If your system uses `sshd`:

```bash
sudo systemctl status sshd
sudo journalctl -u sshd -b --no-pager
```

---

## Uninstall

Remove the systemd override:

```bash
sudo rm -f /etc/systemd/system/ssh.service.d/override.conf
```

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Restart SSH:

```bash
sudo systemctl restart ssh
```

For systems using `sshd`:

```bash
sudo rm -f /etc/systemd/system/sshd.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart sshd
```

---

## Security Warning

The one-line installation command downloads a remote script and executes it with `sudo` privileges:

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash
```

Only use this command if you trust the repository and its contents.

For additional security, download and inspect the script first:

```bash
curl -fsSL -o /tmp/install.sh https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh
```

Then:

```bash
cat /tmp/install.sh
```

After reviewing it:

```bash
sudo bash /tmp/install.sh
```

---

## SSH Access Warning

Be careful when changing SSH `ListenAddress` settings.

If SSH is configured to listen only on a VPN/Tailscale IP, make sure you have another way to access your VPS, such as:

* VPS Web Console
* VNC Console
* Serial Console
* Provider Rescue Console

This is especially important when testing SSH configuration or systemd changes.

A configuration error can otherwise make the VPS inaccessible over SSH.

---

## License

MIT License
