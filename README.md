# OpenCode iOS Client

> Fork 自 [grapeot/opencode_ios_client](https://github.com/grapeot/opencode_ios_client)，在原版基础上做了大量功能增强与体验优化。

OpenCode 的 iOS/iPadOS 原生客户端，用于远程连接 OpenCode 服务端、发送指令、监控 AI 工作进度、浏览代码变更。让你在沙发上、通勤中或任何远离电脑的场景下，掏出手机就能看 AI 干到哪了。

<p align="center">
  <img src="docs/logo_light.png" alt="OpenCode iOS Client" width="120">
</p>

## 相比上游的主要改动

本 fork 在原版基础上新增 / 增强了以下功能：

### 核心功能

| 功能 | 说明 |
|------|------|
| **Agent 选择** | 支持从多个 Agent 中选择（OpenCode-Builder 默认），下拉列表切换 |
| **Project / Workspace 选择** | 按项目过滤 Session 列表，支持自定义路径，解决多项目场景下"看不到 Session"的问题 |
| **SSH Tunnel 远程访问** | 集成 Citadel SSH 库，通过 VPS 建立 SSH 隧道，实现真正的远程访问 |
| **语音输入** | 集成 AI Builder Speech Recognition，录音后自动转写追加到输入框 |
| **Context 用量环** | Chat 顶部显示 Token / Cost 占用情况，点击查看明细 |
| **Session 管理增强** | 删除、归档、标题自动更新、按更新时间排序、草稿持久化 |
| **多机器切换** | Chat 页面新增"连接"按钮，支持在不同 OpenCode Server 之间快速切换 |

### 性能优化

- **行级状态解耦**：MessageRowView 移除全局 AppState 直连，仅订阅必要数据
- **Scroll Anchor O(1) 签名**：从全量拼接改为基于 count + signature 的轻量计算
- **Markdown 快速路径**：纯文本消息跳过 MarkdownUI 解析，直接用 Text 渲染
- **消息分段加载**：默认只拉最近 3 轮对话，下拉加载更多历史

### iPad / Vision Pro 适配

- **三栏布局**：NavigationSplitView — 左侧 Files + Sessions / 中间 Preview / 右侧 Chat
- **可拖动分栏**：支持拖拽调整各栏宽度
- **文件预览内联**：点击文件直接在 Preview 栏打开，不弹 sheet
- **外接键盘**：回车发送消息

### UI / UX 改进

- **图片查看器**：支持缩放与分享
- **Todo 渲染**：todowrite 工具调用直接渲染为 Todo 列表
- **Per-session 模型记忆**：切换 Session 自动恢复该 Session 上次选择的模型
- **输入草稿持久化**：切换 Session 后未发送的输入不会丢失
- **卡片视觉统一**：tool / patch / permission / user message 统一风格
- **Activity 计时**：每个 turn 保留耗时记录，支持持久化

### 稳定性修复

- Swift 6 / MainActor / deprecation 兼容
- SSH NIO channel state 并发崩溃修复
- Session 快速切换竞态修复
- SSE 重连状态补偿
- Busy/Retry 会话卡死修复
- 前后台切换时 SSH/SSE 自动恢复

## 功能概述

- **Chat**：发送消息、切换模型 / Agent、查看 AI 回复与工具调用、语音输入
- **Files**：文件树、Session 变更、代码/文档预览、图片查看
- **Settings**：服务器连接、SSH Tunnel、认证、主题、语音转写配置、Project 选择

## 环境要求

- iOS / iPadOS 17.0+
- Xcode 15+
- 运行中的 OpenCode Server（`opencode serve` 或 `opencode web`）

## 快速开始（局域网）

1. 在 Mac 上启动 OpenCode：`opencode serve --port 4096`
2. 打开 iOS App，进入 Settings，填写服务器地址（如 `http://192.168.x.x:4096`）
3. 点击 Test Connection 验证连接
4. 在 Chat 中创建或选择 Session，开始对话

## 远程访问

OpenCode iOS 默认为局域网使用。如需远程访问，有两种方案：

### 方案 1：HTTPS + 公网服务器（推荐）

将 OpenCode 部署在公网服务器上，使用 HTTPS 加密：

1. 服务器上运行 OpenCode，配置 TLS 和认证
2. iOS App Settings 中填写 `https://your-server.com:4096`
3. 配置 Basic Auth 用户名/密码

> **安全提示**：公网暴露必须使用 HTTPS + 强认证。

### 方案 2：SSH Tunnel（本 fork 新增）

通过公网 VPS 建立 SSH 隧道访问家里的 OpenCode：

```
iOS App → VPS (SSH) → VPS:18080 → 家里 OpenCode:4096
```

**前提条件**：
- 一台公网 VPS
- 家里机器与 VPS 建立反向隧道

**设置步骤**：

1. **家里机器**建立反向隧道到 VPS：
   ```bash
   ssh -N -T -R 127.0.0.1:18080:127.0.0.1:4096 user@your-vps
   ```

2. **iOS App** 配置 SSH Tunnel：
    - Settings → SSH Tunnel → 开启
    - 填写 VPS 地址、用户名、远程端口（18080）
    - 复制公钥，添加到 VPS 的 `~/.ssh/authorized_keys`
    - 复制 App 生成的 reverse tunnel command，在电脑端执行
    - Server Address 改为 `127.0.0.1:4096`（通过隧道访问），然后点 Test Connection

> **注意**：SSH Tunnel 基于 Citadel 实现，支持 Ed25519 密钥、TOFU 安全校验、前后台自动恢复。

## 当前支持的模型

| 显示名称 | Provider | Model ID |
|----------|----------|----------|
| GLM-5（默认） | zai-coding-plan | glm-5 |
| Opus 4.6 | anthropic | claude-opus-4-6 |
| Sonnet 4.6 | anthropic | claude-sonnet-4-6 |
| GPT-5.3 Codex | openai | gpt-5.3-codex |
| GPT-5.2 | openai | gpt-5.2 |
| Gemini 3.1 Pro | google | gemini-3.1-pro-preview |
| Gemini 3 Flash | google | gemini-3-flash-preview |

## 内置 Agent

| Agent | Mode |
|-------|------|
| OpenCode-Builder（默认） | all |
| Sisyphus (Ultraworker) | primary |
| Hephaestus (Deep Agent) | primary |
| Prometheus (Plan Builder) | all |
| Atlas (Plan Executor) | primary |

## 项目结构

```
opencode_ios_client/
├── README.md
├── docs/                        # 文档
│   ├── OpenCode_iOS_Client_PRD.md   # 产品需求文档
│   ├── OpenCode_iOS_Client_RFC.md   # 技术方案文档
│   ├── OpenCode_Web_API.md          # OpenCode API 说明
│   ├── WORKING.md                   # 开发进度与决策记录
│   ├── dev_localization.md          # 本地化规划
│   └── lessons.md                   # 开发经验教训
├── OpenCodeClient/
│   ├── OpenCodeClient.xcodeproj/    # Xcode 工程
│   ├── OpenCodeClient/              # 主程序源码
│   │   ├── Models/                  # 数据模型（Session, Message, Project, AgentInfo 等）
│   │   ├── Services/                # 网络与系统服务（API, SSE, SSH, 语音）
│   │   ├── Stores/                  # 状态管理（Session, Message, File, Todo）
│   │   ├── Controllers/             # 权限控制、活动追踪
│   │   ├── Utils/                   # 工具类（Keychain, PathNormalizer 等）
│   │   ├── Views/                   # SwiftUI 视图（Chat, Files, Settings）
│   │   └── Support/                 # 本地化资源
│   ├── OpenCodeClientTests/         # 单元测试
│   └── OpenCodeClientUITests/       # UI 测试
└── scripts/
    └── resize_icon.py               # App Icon 缩放脚本
```

## 依赖

| 库 | 版本 | 用途 |
|----|------|------|
| [Citadel](https://github.com/orlandos-nl/Citadel) | ≥ 0.12.0 | SSH Tunnel 连接 |
| [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) | ≥ 2.4.1 | Markdown 渲染 |

## 文档

- [`docs/OpenCode_iOS_Client_PRD.md`](docs/OpenCode_iOS_Client_PRD.md) — 产品需求文档
- [`docs/OpenCode_iOS_Client_RFC.md`](docs/OpenCode_iOS_Client_RFC.md) — 技术方案文档
- [`docs/OpenCode_Web_API.md`](docs/OpenCode_Web_API.md) — OpenCode API 说明
- [`docs/WORKING.md`](docs/WORKING.md) — 开发进度与决策记录
- [`docs/lessons.md`](docs/lessons.md) — 开发过程中的经验教训

## 致谢

- 原项目：[grapeot/opencode_ios_client](https://github.com/grapeot/opencode_ios_client)
- 社区贡献者：[@xiang-lee](https://github.com/xiang-lee)、[@jeromexlee](https://github.com/jeromexlee)

## License

与 [OpenCode](https://github.com/opencode-ai/opencode) 保持一致。
