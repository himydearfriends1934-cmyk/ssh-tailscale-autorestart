# SSH Auto-Restart for Tailscale / VPN IP

### ⚡ 一键安装 / 交互管理

```bash
curl -fL -o install.sh https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh && sudo bash install.sh
```

**或者通过管道直接执行对应命令：**
```bash
# 1) 设置仅 Tailscale IPv4 登录 (自动联动配置自启动)
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash -s -- 1

# 2) 恢复到网络原来的状态 (恢复公网 IP 登录)
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash -s -- 2
```

---

一个用于 VPS 的轻量级 SSH 自动恢复工具。

当 SSH 服务绑定了 Tailscale / VPN IP 时，如果 VPS 重启、Tailscale IP 消失、重新出现或发生变化，SSH 服务可能无法继续监听新的 IP。

本项目通过 `systemd` + Tailscale IP watcher 自动检测并恢复 SSH 服务。

---

## Features

* 自动检测 `ssh.service` / `sshd.service`
* 自动检测 `tailscaled.service`
* 监控真实的 Tailscale IPv4 地址
* **仅需关注两个网络状态**：
  * **状态 1**：一键设置仅 Tailscale IPv4 SSH 登录（**自动联动启用 Tailscale 自启动守护**）
  * **状态 2**：一键恢复网络原始状态（恢复公网 IP 登录）
* **支持彻底卸载与清理**：
  * 随时删除 Tailscale 自启动监控服务
  * 彻底删除 Tailscale 软件及配置（自带防失联安全回滚保护）
* Tailscale IP 变动/消失/恢复时自动重启并重绑 SSH
* SSH 服务异常退出时由 systemd 自动恢复
* 重启 SSH 前执行 `sshd -t` 语法预检，并验证最终监听地址确实只有 Tailscale IPv4
* 安装失败、SSH 重启失败或有效配置不符合预期时自动安全回滚
* 不删除 SSH keys，保障系统安全

---

## Requirements

目前主要面向使用 `systemd` 的 Linux VPS。

需要：
* Linux (Debian, Ubuntu, CentOS, RHEL, Fedora, Rocky, Alma, Arch, Alpine 等)
* systemd
* OpenSSH Server
* Tailscale（选项 1 会自动检测并提示）
* `flock`（通常由 `util-linux` 提供）
* root 权限

---

# 交互管理菜单与命令行选项

在终端直接运行 `sudo ./install.sh` 会显示菜单：

```text
============================================================
 SSH & Tailscale 网络管理工具
============================================================
1) 设置仅 Tailscale IPv4 SSH (自动配置自启动)
2) 恢复到网络原来的状态 (恢复公网 IP 登录)
3) 删除 Tailscale 自启动
4) 删除 Tailscale
5) 退出脚本
============================================================
```

### 命令行非交互执行

```bash
sudo ./install.sh 1                    # 设置仅 Tailscale IPv4 SSH (自动配置自启动)
sudo ./install.sh 2                    # 恢复到网络原来的状态 (恢复公网 IP 登录)
sudo ./install.sh 3                    # 删除 Tailscale 自启动
sudo ./install.sh 4                    # 彻底删除 Tailscale 软件及配置
```

---

# 菜单功能详解

### 1. 设置仅 Tailscale IPv4 SSH (自动配置自启动)
* **核心优势**：只要设置 Tailscale IP 登录，**自动联动安装并运行 Tailscale 自启动守护**！
* **杜绝公网爆破**：将 SSH 端口完全收敛在 Tailscale 内网中，不对公网开放。
* **双重保障**：
  1. 自动安装 `tailscale-ssh-watch` 独立守护服务与 systemd 覆写，确保机器重启或 Tailscale 重新分配 IP 时，SSH 自动重新绑定新 IP。
  2. 自动备份 `/etc/ssh/sshd_config` 到 `.bak` 文件。
  3. 写入带专用标记的 `ListenAddress <Tailscale-IP>`。
  4. 严格执行 `sshd -t` 语法检测，若出现任何异常自动回滚，杜绝失联。

### 2. 恢复到网络原来的状态 (恢复公网 IP 登录)
* **完整还原**：若存在安装前备份，优先恢复完整的 `/etc/ssh/sshd_config`。
* 没有备份时，只移除由本项目管理的 `ListenAddress` 标记块，不会批量取消用户自己的注释。
* **恢复全网卡访问**：重启 SSH 后即可通过原有公网 IP / 域名正常登录 VPS。

### 3. 删除 Tailscale 自启动
* 如果你打算停止使用 Tailscale 守护监控，选择此项可安全卸载：
  * 停止并删除 `tailscale-ssh-watch.service` 守护进程
  * 清理 `/usr/local/sbin/tailscale-ssh-watch` 脚本
  * 清除 SSH systemd override 配置，并重载 systemd

### 4. 彻底删除 Tailscale
* 彻底从系统中卸载 Tailscale 软件及其相关配置。
* **贴心防失联保护**：如果检测到当前 SSH 正处于【仅 Tailscale IP 登录】状态，脚本会**自动先恢复 SSH 公网 IP 登录**，然后再卸载 Tailscale，防止用户被永久关在门外！
* 自动适配 apt / yum / dnf / pacman / apk / zypper 包管理器进行卸载，并清理残留数据目录。

---

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

删除本项目的 watcher 和 systemd 配置：

```bash
curl -fsSL https://raw.githubusercontent.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart/main/install.sh | sudo bash -s -- uninstall
```

也可以在交互菜单中选择 `3`。该操作只删除本项目的自动监控配置，不会自动把 SSH 从 Tailscale IP 恢复到公网。
如果需要恢复公网监听，请先选择菜单 `2`。

菜单 `4` 才是彻底卸载 Tailscale。交互模式会先确认，再恢复 SSH 公网监听，之后才停止并卸载 Tailscale。

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

* 在 `/etc/systemd/system/` 下配置 service 及 override
* 在 `/usr/local/sbin/` 下安装 watcher 监控脚本
* 重启 SSH service 以应用变更

关于配置文件安全：
* **选项 1** 会显式修改 `/etc/ssh/sshd_config`，把 SSH 限制到当前 Tailscale IPv4，同时安装 watcher。
* 修改前会备份原配置，修改后执行 `sshd -t`，并用 `sshd -T` 检查最终有效监听地址；检查失败会恢复备份。
* **从不修改** SSH 身份认证（密码/证书/端口）等其他配置。
* **从不删除** 任何 SSH Keys 或密钥文件。

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
* dry-run 模式
* ShellCheck CI 和 GitHub Actions 自动测试

---

# License

目前仓库未指定正式开源许可证。

如果准备公开长期维护，建议添加一个明确的 LICENSE，例如 MIT License。

---

# Project

GitHub:

https://github.com/himydearfriends1934-cmyk/ssh-tailscale-autorestart
