# 台式机 OpenCode Server 启动配置指南

## 目的

在台式机上配置 OpenCode Server，使其通过 **launchd** 管理，满足以下要求：
1. 开机自启，崩溃自动重启
2. 支持 iOS 客户端远程切换目标项目目录（scope switch）
3. 通过 SSH 反向隧道让手机/iPad 远程访问

> **重要**：iOS 客户端的"连接"功能依赖 launchd 的 `com.opencode.server.plist` 文件。
> 如果不用 launchd 而是手动 `opencode serve`，iOS 客户端将无法切换目标项目。

---

## 第 1 步：安装 OpenCode

```bash
# 如果还没装 opencode
npm install -g opencode-ai

# 验证安装
which opencode
opencode --version
```

记下 opencode 的**实际二进制路径**，后续需要填入 plist：

```bash
# 找到真实的二进制路径（不是 symlink）
OPENCODE_BIN=$(readlink -f $(which opencode) 2>/dev/null || realpath $(which opencode) 2>/dev/null)
echo "二进制路径: $OPENCODE_BIN"

# 如果上面命令找不到，手动查找
ls ~/.npm-global/lib/node_modules/opencode-ai/node_modules/opencode-darwin-arm64/bin/opencode 2>/dev/null
```

---

## 第 2 步：创建 OpenCode Server 的 launchd 配置

```bash
mkdir -p ~/opencode-tunnel
```

创建文件 `~/Library/LaunchAgents/com.opencode.server.plist`，内容如下：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>【替换为台式机的 $HOME 路径，例如 /Users/challenwang】</string>
        <key>OPENCODE_SERVER_HOST</key>
        <string>0.0.0.0</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:【替换为 opencode 所在的 bin 目录】</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>Label</key>
    <string>com.opencode.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>【替换为第 1 步找到的 opencode 二进制完整路径】</string>
        <string>serve</string>
        <string>--hostname</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>4096</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>【$HOME 路径】/opencode-tunnel/server-stderr.log</string>
    <key>StandardOutPath</key>
    <string>【$HOME 路径】/opencode-tunnel/server-stdout.log</string>
    <key>WorkingDirectory</key>
    <string>【替换为默认的工作目录，例如台式机的 Desktop 路径】</string>
</dict>
</plist>
```

**必须满足的关键字段**：

| 字段 | 要求 | 原因 |
|------|------|------|
| `KeepAlive` | 必须为 `true` | 进程被杀后 launchd 自动重启 |
| `Label` | 必须为 `com.opencode.server` | iOS 客户端用此名称检测 launchd |
| `WorkingDirectory` | 必须存在 | iOS 客户端通过 plutil 修改此字段来切换目标项目 |
| `--hostname 0.0.0.0` | 必须是 `0.0.0.0` | 允许局域网和隧道访问，`127.0.0.1` 只能本地访问 |
| `--port 4096` | 建议 `4096` | iOS 客户端默认端口 |

---

## 第 3 步：创建 SSH 反向隧道

创建隧道脚本 `~/opencode-tunnel/tunnel.sh`：

```bash
#!/bin/bash
# OpenCode 反向隧道自动重连脚本

VPS_HOST="43.134.93.25"
VPS_USER="root"
VPS_PORT="20080"       # ← 台式机用 20080，笔记本用 20081
LOCAL_PORT="4096"
SSH_KEY="$HOME/.ssh/id_ed25519"
LOG_FILE="$HOME/opencode-tunnel/tunnel.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

while true; do
    log "正在建立反向隧道 → $VPS_HOST:$VPS_PORT..."

    ssh -N -T \
        -R 127.0.0.1:${VPS_PORT}:127.0.0.1:${LOCAL_PORT} \
        -i "$SSH_KEY" \
        -o "ServerAliveInterval=30" \
        -o "ServerAliveCountMax=3" \
        -o "ExitOnForwardFailure=yes" \
        -o "ConnectTimeout=10" \
        -o "StrictHostKeyChecking=no" \
        ${VPS_USER}@${VPS_HOST} 2>> "$LOG_FILE"

    EXIT_CODE=$?
    log "隧道断开 (exit code: $EXIT_CODE)，10 秒后重连..."
    sleep 10
done
```

```bash
chmod +x ~/opencode-tunnel/tunnel.sh
```

创建隧道的 launchd 配置 `~/Library/LaunchAgents/com.opencode.tunnel.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.opencode.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>【$HOME 路径】/opencode-tunnel/tunnel.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>【$HOME 路径】/opencode-tunnel/tunnel-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>【$HOME 路径】/opencode-tunnel/tunnel-stderr.log</string>
</dict>
</plist>
```

---

## 第 4 步：加载服务并验证

```bash
# 加载 OpenCode Server
launchctl load ~/Library/LaunchAgents/com.opencode.server.plist

# 加载隧道
launchctl load ~/Library/LaunchAgents/com.opencode.tunnel.plist

# 检查服务状态
launchctl list | grep opencode
# 期望看到 com.opencode.server 和 com.opencode.tunnel

# 验证 Server 运行
curl -s http://127.0.0.1:4096/global/health
# 期望: {"healthy":true,"version":"..."}

# 验证隧道（通过 VPS 侧）
ssh -o ConnectTimeout=5 -i ~/.ssh/id_ed25519 root@43.134.93.25 \
    "curl -s http://127.0.0.1:20080/global/health 2>&1"
# 期望: {"healthy":true,"version":"..."}
```

---

## 第 5 步：确认台式机的 SSH 密钥已添加到 VPS

```bash
# 如果台式机还没有 SSH 密钥
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519

# 将公钥添加到 VPS
ssh-copy-id -i ~/.ssh/id_ed25519 root@43.134.93.25
```

---

## iOS 客户端连接台式机

在 iOS App 的设置页面中，服务器地址填写：

- **局域网**（同一 Wi-Fi）：`http://台式机内网IP:4096`
- **远程**（通过 VPS）：需要在 VPS 上配置 nginx 反代或直接 SSH 端口转发，端口为 `20080`

---

## 端口分配表

| 设备 | OpenCode 本地端口 | VPS 转发端口 |
|------|-------------------|-------------|
| 台式机 | 4096 | 20080 |
| 笔记本 | 4096 | 20081 |

---

## 常见问题

### 服务没启动
```bash
# 查看日志
tail -50 ~/opencode-tunnel/server-stderr.log
tail -50 ~/opencode-tunnel/server-stdout.log
```

### 端口被占
```bash
lsof -i :4096
# 如有非 opencode 进程占用，kill 掉后重新加载
kill <PID>
launchctl unload ~/Library/LaunchAgents/com.opencode.server.plist
launchctl load ~/Library/LaunchAgents/com.opencode.server.plist
```

### 重新加载服务（修改 plist 后）
```bash
launchctl unload ~/Library/LaunchAgents/com.opencode.server.plist
launchctl load ~/Library/LaunchAgents/com.opencode.server.plist
```
