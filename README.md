# SSH Auto-Restart for Tailscale / VPN IP Binding

A lightweight `systemd` override configuration to automatically resolve SSH boot-time race conditions when binding `sshd` to specific virtual network interface IPs (such as Tailscale, WireGuard, or ZeroTier).

## Quick Install (One-Liner)

Run the following command on your VPS (click the copy icon on the right to copy):

```bash
curl -sSL [https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh](https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh) | sudo bash
