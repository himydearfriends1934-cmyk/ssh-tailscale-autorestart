# SSH Auto-Restart for Tailscale / VPN IP Binding

A lightweight `systemd` override configuration to automatically resolve SSH boot-time race conditions when binding `sshd` to specific virtual network interface IPs (such as Tailscale, WireGuard, or ZeroTier).

## Quick Install (One-Liner)

> **Note**: Hover over the code block below and click the **Copy icon** on the right side to copy the clean command directly into your terminal.

```bash
curl -sSL [https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh](https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh) | sudo bash
