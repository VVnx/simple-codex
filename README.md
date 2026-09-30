# simple-codex

一个完全独立的纯 Swift macOS 工具。它把微信 iLink 私聊转给本机已安装的官方
`codex app-server`，再把 Codex 的最终文字结果回复到微信。

默认交付形态是参考 `simple-usage` 生命周期实现的原生菜单栏 App：没有 Dock 图标，
点击菜单栏气泡图标即可选择工作目录、扫码连接、查看状态、停止监听或退出登录。
CLI 同时保留，方便调试和自动化。

## 云端 Slack 后端（实验性）

新增独立 Python 云端中继：微信主人文字 → 已有 dot 的 Slack 私聊 → 对应线程回复回微信。
PC 可关机，直接 Slack 聊天和原 Swift/Codex 模式保留。需要自行授权的常驻云主机、Slack
用户 OAuth 与微信会话；当前未部署，未完成真实微信/独立 OAuth 端到端验证。
配置、Docker、恢复和限制见 [cloud/README.md](cloud/README.md)。

## 首版边界

- 单微信账号、单主人；登录响应没有主人 ID 时，第一条合法私聊原子固定主人；
- 接收完成态私聊文字和语音转写文字；不接收群聊、图片或其他附件；
- 所有消息复用一个持久 Codex thread，绑定一个固定工作目录；
- 默认 `workspace-write`、禁用网络沙箱能力、`approvalPolicy=never`；无人值守场景出现
  命令/文件审批、补充输入、临时权限或 MCP 表单时会拒绝，不会等待 Mac 端确认；
- 微信 token 只存 macOS Keychain；cursor、主人、thread 和有界持久队列写入权限
  `0600` 的本地状态文件；进程锁阻止两份工具重复消费；
- 收到消息后先把消息和 cursor 原子落盘再执行。若 Codex 执行期间进程退出，重启后只
  回复“任务已中止”，不会自动重跑可能带副作用的任务；回复按稳定 client ID 分片续传。

这里使用的是仓库现有实现所采用的微信 iLink bot HTTP 合同，并非面向所有开发者承诺
长期兼容的公开 SDK；微信服务字段或策略变化时可能需要同步适配。正式发布前还应补充
Developer ID 签名/公证、图片输入、真实账号端到端测试和隐私说明。

## 运行

要求 macOS 13+、Swift 5.10+，以及已经安装并登录的 Codex App 或 Codex CLI。

```bash
git clone https://github.com/VVnx/simple-codex.git
cd simple-codex
swift run wechat-codex --workspace /absolute/path/to/workspace
```

首次运行会生成并打开微信二维码。后续凭据保存在 Keychain，不再重复扫码。

### 菜单栏 App

```bash
./scripts/build-app.sh
open "dist/WeChat Codex.app"
```

App 启动后不会自动监听。点击菜单栏气泡图标，先选择工作目录，再点击“连接微信并开始
监听”；需要扫码时会弹出原生二维码面板。

常用参数：

```bash
# 只读
swift run wechat-codex -w /path --sandbox read-only

# 指定 Codex CLI、模型和思考强度
swift run wechat-codex -w /path \
  --codex /Applications/Codex.app/Contents/Resources/codex \
  --model <model-id> --effort medium

# 清除微信凭据、主人、cursor、thread 和队列
swift run wechat-codex --logout
```

`danger-full-access` 会允许 Codex 访问工作目录之外的本机路径，只应在明确理解风险时使用。

## 结构

```text
Sources/WeChatCodexBridge/
├── WeChatClient.swift            # iLink 登录、长轮询和发消息
├── KeychainCredentialStore.swift # 微信凭据
├── BridgeStateStore.swift        # cursor、主人、thread、持久队列和进程锁
├── CodexAppServer.swift          # stdio JSON-RPC 传输
├── CodexAgent.swift              # thread/turn、完成结算和无人值守拒绝策略
└── WeChatCodexBridge.swift       # 单主人过滤、队列与编排
Sources/WeChatCodexMenuBar/
└── main.swift                    # NSStatusItem 菜单栏 App 与扫码面板
```

包只依赖 Apple 系统框架和 Swift 标准库；没有任何仓库内 target 或 path dependency。

## 验证

```bash
swift test
swift build -c release -Xswiftc -warnings-as-errors
```
