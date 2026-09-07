# SSH Auto-Restart for Tailscale / VPN IP Binding

A lightweight `systemd` override configuration to automatically resolve SSH boot-time race conditions when binding `sshd` to specific virtual network interface IPs (such as Tailscale, WireGuard, or ZeroTier).

## Problem

When you configure a specific internal IP in `/etc/ssh/sshd_config`:

```sshd
ListenAddress 100.x.x.x
