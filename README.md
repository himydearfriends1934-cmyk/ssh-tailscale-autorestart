# SSH Auto-Restart for Tailscale / VPN IP

一个用于 VPS 的轻量级 SSH 自动恢复工具。

当 SSH 服务绑定了 Tailscale / VPN IP 时，如果 VPS 重启、Tailscale IP 消失、重新出现或发生变化，SSH 服务可能无法继续监听新的 IP。

本项目通过 `systemd` + Tailscale IP watcher 自动检测并恢复 SSH 服务。

## Features

* 自动检测 `ssh.service` / `sshd.service`
* 自动检测 `tailscaled.service`
* 监控真实的 Tailscale IPv4 地址
* Tailscale IP 首次出现时自动重启 SSH
* Tailscale IP 消失后等待恢复
* Tailscale IP 恢复后自动重启 SSH
* Tailscale IP 发生变化时自动重启 SSH
* SSH 服务异常退出时由 systemd 自动恢复
* 重启 SSH 前自动执行 `sshd -t`
* 独立的 systemd watcher 服务
* 支持安装 / 卸载
* 不修改 `/etc/ssh/sshd_config`
* 不删除 SSH keys
* 不删除 OpenSSH
* 不删除 Tailscale

---

## Requirements

目前 v2 主要面向使用 `systemd` 的 Linux VPS。

需要：

* Linux
* systemd
* OpenSSH Server
* Tailscale
* `tailscaled.service`
* `tailscale` 命令
* root 权限

检查：

```bash
systemctl --version
```

检查 SSH：

```bash
systemctl status ssh
```

或者：

```bash
systemctl status sshd
```

检查 Tailscale：

```bash
systemctl status tailscaled
```

检查 Tailscale IP：

```bash
tailscale ip -4
```

正常情况下应该看到类似：

```text
100.x.x.x
```

---

# Quick Install

在 VPS 上运行：

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash -s -- install
```

也可以下载后使用交互菜单：

```text
curl -fL -o install.sh \
  https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh
sudo bash install.sh
```

管道执行时请显式指定 `install`，因为脚本内容本身占用了标准输入。

安装成功时只显示：

```text
Installation completed.
```

不带参数运行下载后的脚本会显示简洁菜单：

```text
1) Install
2) Delete configuration and restore the pre-install state
3) Exit
```

选择第 2 项时会先要求确认，然后删除本项目配置并恢复 SSH 到安装前的 systemd 状态。

---

# Install

选择：

```text
1
```

安装程序会：

1. 检测 SSH 服务
2. 检测 Tailscale
3. 检查 `tailscaled.service`
4. 检查 Tailscale 命令
5. 验证 SSH 配置
6. 创建 SSH systemd override
7. 安装 Tailscale IP watcher
8. 创建 `tailscale-ssh-watch.service`
9. 启用 watcher
10. 重启 SSH
11. 启动 watcher

---

# How It Works

v2 不再单纯依赖：

```ini
Restart=always
```

因为 `Restart=always` 只能处理 SSH 进程退出，无法判断 Tailscale IP 是否发生变化。

v2 使用独立 watcher：

```text
                 Tailscale
                     │
                     ▼
              tailscaled.service
                     │
                     ▼
              Tailscale IPv4
                     │
                     ▼
       tailscale-ssh-watch.service
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
       IP出现       IP变化      IP恢复
          │          │          │
          └──────────┼──────────┘
                     ▼
                Restart SSH
```

Watcher 默认每 **2 秒**检查一次：

```bash
tailscale ip -4
```

---

# Tailscale IP Changes

例如 VPS 当前：

```text
100.64.10.20
```

后来 Tailscale IP 变成：

```text
100.64.10.35
```

watcher 会检测到：

```text
Tailscale IPv4 changed:
  old: 100.64.10.20
  new: 100.64.10.35
```

然后自动执行：

```bash
systemctl restart ssh.service
```

或者：

```bash
systemctl restart sshd.service
```

具体取决于系统检测到的 SSH service 名称。

---

# Tailscale IP Disappears

如果 Tailscale 暂时没有 IPv4：

```text
Tailscale IPv4 disappeared.
Waiting for Tailscale IPv4 to return.
```

此时不会疯狂重启 SSH。

当 Tailscale IPv4 恢复：

```text
Tailscale IPv4 detected: 100.x.x.x
```

watcher 会重新启动 SSH。

---

# SSH Crash Recovery

安装后 SSH service 会增加：

```ini
[Service]
Restart=on-failure
RestartSec=3s
```

因此 SSH 进程异常退出时，systemd 会尝试自动恢复。

与 `Restart=always` 相比，这种方式不会把正常退出也当成需要无限重启的情况。

---

# SSH Configuration Validation

在安装以及 watcher 重启 SSH 前，会尝试执行：

```bash
sshd -t
```

如果 SSH 配置存在错误：

```text
SSH configuration is invalid.
SSH restart skipped.
```

这样可以避免因为明显的 SSH 配置错误而主动重启 SSH。

也可以手动检查：

```bash
sshd -t
```

如果系统找不到 `sshd`：

```bash
/usr/sbin/sshd -t
```

---

# Installed Files

安装后主要会创建：

### SSH systemd override

```text
/etc/systemd/system/ssh.service.d/90-tailscale-ssh-autorestart.conf
```

或者：

```text
/etc/systemd/system/sshd.service.d/90-tailscale-ssh-autorestart.conf
```

内容类似：

```ini
[Unit]
# Managed by ssh-tailscale-autorestart
After=tailscaled.service
Wants=tailscaled.service
StartLimitIntervalSec=0

[Service]
RestartPreventExitStatus=
Restart=on-failure
RestartSec=3s
```

### Tailscale watcher

```text
/usr/local/sbin/tailscale-ssh-watch
```

### Watcher service

```text
/etc/systemd/system/tailscale-ssh-watch.service
```

watcher 只依赖网络和 `tailscaled.service` 的启动顺序，不使用
`Requires=ssh.service`。这样 watcher 在 SSH 启动失败时仍然可以运行并重试 SSH，
同时 SSH 重启不会把 watcher 自己连带停止。

---

# Check Status

检查 SSH：

```bash
systemctl status ssh
```

或者：

```bash
systemctl status sshd
```

检查 watcher：

```bash
systemctl status tailscale-ssh-watch.service
```

检查 Tailscale：

```bash
systemctl status tailscaled.service
```

---

# Watch Logs

实时查看 watcher：

```bash
journalctl -u tailscale-ssh-watch.service -f
```

查看本次启动以来的日志：

```bash
journalctl -u tailscale-ssh-watch.service -b --no-pager
```

查看 SSH：

```bash
journalctl -u ssh.service -b --no-pager
```

或者：

```bash
journalctl -u sshd.service -b --no-pager
```

---

# Check Tailscale IP

```bash
tailscale ip -4
```

例如：

```text
100.64.10.20
```

也可以检查 Tailscale 状态：

```bash
tailscale status
```

---

# Check systemd Configuration

查看 SSH 最终配置：

```bash
systemctl cat ssh.service
```

或者：

```bash
systemctl cat sshd.service
```

查看 watcher：

```bash
systemctl cat tailscale-ssh-watch.service
```

查看 systemd 是否识别配置：

```bash
systemctl daemon-reload
```

---

# Uninstall

运行：

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash -s -- uninstall
```

也可以在交互菜单中选择 `2`，确认后删除本项目配置并恢复 SSH。

卸载只会删除带有本项目标记的文件，以及能够明确识别为旧版本生成的文件：

```text
/etc/systemd/system/ssh.service.d/90-tailscale-ssh-autorestart.conf
```

或：

```text
/etc/systemd/system/sshd.service.d/90-tailscale-ssh-autorestart.conf
```

以及 watcher 文件：

```text
/usr/local/sbin/tailscale-ssh-watch
```

和：

```text
/etc/systemd/system/tailscale-ssh-watch.service
```

然后重新加载 systemd，并恢复 SSH 服务到项目安装前的 systemd 配置。
未知的同名文件会被保留并显示警告，不会被强制删除。

---

# What Uninstall Does NOT Remove

卸载不会删除：

* OpenSSH
* Tailscale
* SSH keys
* `/etc/ssh/sshd_config`
* `/etc/ssh/sshd_config.d/`
* Tailscale 配置
* 其他 SSH 配置

---

# Important: SSH Lockout Prevention

如果你的 SSH 配置类似：

```text
ListenAddress 100.x.x.x
```

也就是 SSH **只监听 Tailscale IP**，安装或修改配置时建议：

**不要关闭当前 SSH 会话。**

最好同时打开第二个 SSH 会话进行测试：

```text
SSH Session #1
     │
     └── 保持连接，不要关闭

SSH Session #2
     │
     └── 测试新的 SSH 连接
```

确认第二个连接正常后，再关闭旧连接。

这是因为任何涉及 SSH service restart 的操作都有可能导致远程 VPS 暂时无法连接。

---

# Why Not Just Use Restart=always?

简单的：

```ini
[Service]
Restart=always
```

只能解决：

```text
sshd 进程退出
       │
       ▼
systemd restart ssh
```

但是无法解决：

```text
Tailscale IP
100.x.x.x
    │
    ▼
IP 消失
    │
    ▼
sshd 进程仍然运行
    │
    ▼
systemd 不认为 SSH 出错
    │
    ▼
SSH 仍然监听旧地址
```

因此 v2 增加了独立的 Tailscale IP watcher。

---

# Security Notes

这个项目需要 root 权限，因为它会：

* 创建 `/etc/systemd/system/`
* 创建 `/usr/local/sbin/`
* 修改 SSH systemd override
* 重启 SSH service

安装脚本本身不会修改：

```text
/etc/ssh/sshd_config
```

也不会修改 SSH authentication 设置。

---

# Manual Installation

如果不希望直接执行远程脚本，可以先下载：

```bash
curl -fL -o install.sh \
  https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh
```

查看：

```bash
less install.sh
```

检查 shell syntax：

```bash
bash -n install.sh
```

然后运行：

```bash
sudo bash install.sh install
```

推荐生产环境使用这种方式，以便在执行前检查脚本内容。

---

# Troubleshooting

## SSH 没有启动

检查：

```bash
systemctl status ssh
```

或者：

```bash
systemctl status sshd
```

检查配置：

```bash
sshd -t
```

查看日志：

```bash
journalctl -u ssh.service -b --no-pager
```

---

## Watcher 没有运行

检查：

```bash
systemctl status tailscale-ssh-watch.service
```

查看：

```bash
journalctl -u tailscale-ssh-watch.service -b --no-pager
```

---

## Tailscale 没有 IP

检查：

```bash
tailscale status
```

以及：

```bash
tailscale ip -4
```

检查：

```bash
systemctl status tailscaled.service
```

---

## 查看 SSH 当前监听地址

```bash
ss -lntp | grep ssh
```

例如：

```text
LISTEN 0 128 100.x.x.x:22
```

如果 SSH 只监听 Tailscale IP，那么 watcher 对你的环境尤其重要。

---

# Roadmap

未来可以考虑增加：

* Tailscale IPv6 支持
* NetworkManager / systemd-networkd 状态检测
* IP 检测间隔可配置
* `sshd -t` 更完善的错误处理
* dry-run 模式
* ShellCheck CI
* GitHub Actions 自动测试

---

# License

目前仓库未指定正式开源许可证。

如果准备公开长期维护，建议添加一个明确的 LICENSE，例如 MIT License。

---

# Project

GitHub:

https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart
