<p align="center">
  <strong>简体中文</strong> | <a href="./README.md">English</a>
</p>

<p align="center">
  <img src="./ios/ClaudeWatch/ClaudeWatch%20iOS/Assets.xcassets/AppLogo.imageset/1.png" width="160" alt="Agent Watcher logo" />
</p>

<h1 align="center">Agent Watcher</h1>

<p align="center">
  把你在 Mac 上运行的 Claude Code / Codex，变成可以从 Apple Watch、iPhone、iPad 远程查看和操作的 AI 编码工作台。
  <br />
  你可以看实时输出、处理审批、发送语音提示词，而不用一直守在电脑前。
</p>

## 这个项目适合什么场景

Agent Watcher 适合这样的使用方式：

- 你在 Mac 上持续跑 Claude Code 或 Codex，但经常会离开工位
- Agent 需要审批时，你希望第一时间在手表上处理，而不是错过
- 你想随时确认当前任务还在运行、已经完成，还是卡在等待审批
- 你想从手表、手机、iPad 发一句跟进提示词，而不需要重新回到 Mac 终端
- 你希望同一套桥接逻辑既支持局域网，也支持私网远程，还支持公网远程

这个项目的核心原则是：

- 审批归属不因为网络模式变化而改变
- session 归属不因为网络模式变化而改变
- `LAN`、`Direct`、`Cloudflare` 只影响“客户端如何连到 bridge”，不影响审批和 session 的判定逻辑

## 主要功能

- Apple Watch 上查看 Claude Code / Codex 的实时输出
- Apple Watch 上直接处理审批
- Apple Watch 上发送语音输入
- iPhone 端负责配对、网络模式选择、状态查看、审批处理、终端预览
- iPad 端提供更大的远程控制界面，并复用与 iPhone 相同的审批与 session 路由逻辑
- Mac 侧 bridge 负责连接 Claude Code、Codex、tmux 和镜像终端
- 支持固定 6 位配对码
- 同时支持三种连接方式：
  - `LAN`
  - `Direct`
  - `Cloudflare`

## 架构

```text
Apple Watch  <--WCSession-->  iPhone / iPad  <--HTTP / SSE-->  Mac 上的 Bridge Server
                                                                  |
                                                                  +--> Claude Code
                                                                  +--> Codex
                                                                  +--> tmux / 镜像终端
```

## 三种部署方式怎么选

| 模式 | 适合场景 | 延迟 | 是否暴露公网 | 说明 |
| --- | --- | --- | --- | --- |
| `LAN` | 家里 / 公司同一 Wi-Fi | 最低 | 否 | 最简单，适合同一局域网 |
| `Direct` | 远程低延迟私网连接 | 通常最优 | 否 | 最推荐，尤其配合 Tailscale |
| `Cloudflare` | 必须从公网 anywhere 访问 | 通常更高 | 是，经由 Cloudflare | 适合无法装 VPN 的情况 |

## 下载与前置依赖

部署前建议先准备好以下工具：

- Node.js 18+：
  - 下载地址：https://nodejs.org/en/download
- Xcode：
  - 官方页面：https://developer.apple.com/xcode/
  - App Store：https://apps.apple.com/us/app/xcode/id497799835
- XcodeGen：
  - 发布页：https://github.com/yonaskolb/XcodeGen/releases
  - Homebrew：`brew install xcodegen`
- `Direct` 模式可选：
  - Tailscale：https://tailscale.com/download
- `Cloudflare` 模式可选：
  - cloudflared：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/

硬件要求：

- 一台运行 Claude Code / Codex 的 Mac
- 一台 iPhone
- 一块与该 iPhone 配对的 Apple Watch（如果你需要手表远程控制）
- 可选：一台 iPad

## GitHub Release 里会放什么

这个项目可以在 GitHub Releases 中附带以下构建产物：

- `Agent Watcher.app`：iPhone 版本
- `Agent Watcher Pad.app`：iPad 版本
- `Agent Watcher.app`：watchOS 版本

需要注意：

- 这些产物本质上仍然是开发构建产物
- 真正安装到你自己的真机上，仍然依赖 Apple 签名和 Developer Mode
- 对绝大多数用户来说，最稳妥的方式仍然是用 Xcode 按下面的步骤自己编译并安装

## 快速开始

### 1. 克隆仓库

```bash
git clone <你的仓库地址>
cd claude-watch
```

### 2. 安装 bridge 依赖

```bash
./skill/setup.sh
```

或者手动安装：

```bash
cd skill/bridge
npm install
```

### 3. 安装 Claude Code hooks

```bash
./skill/setup-hooks.sh
```

如果你的 bridge 不是默认端口，也可以手动指定：

```bash
./skill/setup-hooks.sh 7860
```

如需移除 hooks：

```bash
./skill/setup-hooks.sh --remove
```

### 4. 启动 bridge

自动生成一个本次 bridge 进程使用的配对码：

```bash
node skill/bridge/server.js
```

或者指定一个固定配对码：

```bash
node skill/bridge/server.js --pairing-code 123456
```

也支持环境变量：

```bash
PAIRING_CODE=123456 node skill/bridge/server.js
```

启动后 bridge 会打印：

- 当前 6 位配对码
- 当前 IP
- 当前端口

这个配对码有几个特点：

- 不会被第一个设备“用掉”
- bridge 运行期间不会自动过期
- 同一个码可以给多个 iPhone / iPad / Watch 使用

### 5. 在 Mac 上启动 Claude Code / Codex

让 bridge 能看到你的 agent session，有两种方式：

#### 方式 A：在 Mac 上用 `claude-watch` / `codex-watch` 启动（推荐）

第 3 步跑完 `./skill/setup-hooks.sh` 之后，脚本会把两个包装命令装到 `~/.local/bin`：

- `claude-watch`：`claude` 的替代命令，启动前会把当前终端注册到 bridge。
- `codex-watch`：`codex` 的替代命令，额外把 `codex exec` 的事件流桥接过来。

先确保 `~/.local/bin` 在 `PATH` 里：

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

验证：

```bash
which claude-watch
which codex-watch
```

**强烈建议放在 tmux 里跑。** bridge 能自动把 `claude-watch` / `codex-watch` 所在的 tmux pane 收养成可持久 session，好处是：

- bridge 重启不丢上下文（可以 kill 掉 `node server.js` 再启一次，session 状态还在）
- 你可以从任意终端 `tmux attach` 回来，手机 / iPad 继续实时推流
- 多个 pane 可以被独立跟踪

```bash
# 一次性创建一个工作 tmux 会话
tmux new -s dev

# 在 tmux 里启动 agent
claude-watch                    # Claude Code 交互模式
codex-watch                     # Codex 交互模式
codex-watch exec "你的 prompt"    # Codex 一次性执行，事件也会推给 bridge

# Ctrl-b d 分离，后续重连：
tmux attach -t dev
```

不用 tmux 也能跑，只是关掉终端窗口 session 就没了。

#### 方式 B：从手机 / iPad 新开 session

如果你人不在 Mac 旁边，可以让 App 去开终端：

1. 先按下一节的步骤把 iPhone / iPad 配对到 bridge
2. 在首页点 `+` 按钮
3. 选 `New Claude Window` 或 `New Codex Window`
4. bridge 会在 Mac 上开一个新的 Terminal.app 窗口，里面的 agent 已经自动桥接好

适合你人已经离开 Mac、临时需要新开一个任务的场景。

### 6. 编译 App

```bash
cd ios/ClaudeWatch
xcodegen generate
open ClaudeWatch.xcodeproj
```

主要 scheme：

- `ClaudeWatch`：iPhone 主 App，并会带上 watch companion
- `ClaudeWatchPad`：iPad App
- `ClaudeWatchWatch`：单独的 watch target

## 如果你是第一次真机安装，这里按这个做

这部分专门写给完全不懂 iOS / watchOS 开发的新手。

### 第一步：安装 Xcode，并且先打开一次

- 从 Apple 下载并安装 Xcode
- 第一次打开时，让它把附加组件装完
- 在 `Xcode > Settings > Accounts` 中登录你的 Apple ID
- 如果 Apple 弹出开发者协议，需要先接受协议

### 第二步：让 Xcode 识别你的设备

- 用数据线把 iPhone 连到 Mac
- 解锁 iPhone
- 如果提示 `Trust This Computer`，选择信任
- 打开 Xcode 的 `Window > Devices and Simulators`
- 确认 iPhone 出现在列表里
- 如果你要装手表 App，确保 Apple Watch 已经和这台 iPhone 正常配对

### 第三步：打开 Developer Mode

开发签名的 App 想跑在真机上，必须开启 Developer Mode。

iPhone / iPad：

1. 在 Xcode 里先选真机运行一次
2. 如果 Xcode 提示需要 Developer Mode，先取消
3. 在设备上打开 `设置 > 隐私与安全性 > 开发者模式`
4. 打开开关
5. 根据提示重启
6. 重启后解锁设备，再确认一次启用开发者模式

Apple Watch：

1. 先尝试从 Xcode 跑一次 watch 目标
2. 在手表上打开 `设置 > 隐私与安全性 > 开发者模式`
3. 按提示开启并确认

### 第四步：配置签名

在 Xcode 中分别进入以下 target 的 `Signing & Capabilities`：

- `ClaudeWatch`
- `ClaudeWatchWatch`
- `ClaudeWatchPad`

都选择你自己的 Team。

当前项目里固定使用的 bundle identifier 是：

- iPhone：`com.nightwatcherphone.han`
- Watch：`com.nightwatcherphone.han.watchkitapp`
- iPad：`com.han.agentwatch.ipad`

如果 Xcode 提示签名或 provisioning profile 有问题：

- 重新选择一次 Team
- 保持自动签名
- 执行 `Product > Clean Build Folder`

### 第五步：真正运行

iPhone + Apple Watch：

1. 选中 `ClaudeWatch` scheme
2. 选择已连接的 iPhone 作为运行目标
3. 点击 `Run`
4. Xcode 会安装 iPhone App，并附带安装嵌入的 watch App

iPad：

1. 选中 `ClaudeWatchPad`
2. 选择已连接的 iPad
3. 点击 `Run`

## 配对方式说明

现在 App 首页会直接先让你选连接模式，然后再输入配对码。

可选模式：

- `Local`
- `Direct`
- `Cloudflare`

通用配对流程：

1. 在 Mac 上启动 bridge
2. 从 bridge 终端读取 6 位配对码
3. 打开 iPhone 或 iPad App
4. 选择连接模式
5. 如果该模式要求地址，就先输入地址
6. 再输入 6 位配对码
7. iPhone 配对成功后，watch 会自动从 iPhone 同步 bridge 凭据

如果 iPhone 已经配对成功，但 watch 还停在 waiting：

- 重新打开一次 watch App
- 等待 companion sync 再走一轮

## 三种部署方式的详细说明

### 方式一：LAN

适合谁：

- 你在家里或者公司，Mac / iPhone / Watch 在同一网络
- 你优先考虑最低延迟
- 你不需要公网访问

需要什么：

- Mac 和 iPhone 在同一局域网
- Mac 上 bridge 正在运行
- 如果希望 Bonjour 自动发现更稳定，Apple Watch 也尽量在同一 Wi-Fi

部署步骤：

1. 在 Mac 上启动 bridge：

```bash
node skill/bridge/server.js --pairing-code 123456
```

2. 打开 iPhone App
3. 选择 `Local`
4. 地址可以留空，走自动发现
5. 如果自动发现失败，手动输入 Mac 的局域网 IP，例如：

```text
192.168.1.21
```

6. 输入 6 位配对码
7. 等待状态页出现 session
8. 再打开 watch App，确认它离开 waiting 页面

什么时候该选 LAN：

- 你和电脑在一个地方
- 你只需要本地网络访问
- 你希望部署步骤最少

LAN 排错建议：

- 自动发现失败时，优先直接输局域网 IP
- 如果 Safari 访问 `/status` 通，但 App 配不上，先确认配对码是不是当前 bridge 打出来的
- 如果 iPhone 已配上但 watch 不同步，先重开 watch App

### 方式二：Direct

适合谁：

- 你需要远程访问
- 你对延迟敏感
- 你不想把 bridge 暴露到公网

最推荐的实现方式：

- Tailscale

为什么推荐：

- 不改 bridge 协议，不改审批逻辑，不改 session 判定
- 只换网络入口
- 如果网络条件好，Tailscale 可以走私网直连，通常比 Cloudflare 更适合这种问答式交互

#### 用 Tailscale 配 Direct 的步骤

1. 在 Mac 上安装 Tailscale：
   - https://tailscale.com/download
2. 在 iPhone / iPad 上安装 Tailscale：
   - 同样从上面的官方页面进入，或者从其链接到的 App Store 页面安装
3. 两台设备登录到同一个 tailnet
4. 在 Mac 上查看 Tailscale 私网 IP：

```bash
tailscale ip -4
```

示例：

```text
100.104.162.41
```

5. 启动 bridge：

```bash
node skill/bridge/server.js --pairing-code 123456
```

6. 打开 iPhone 或 iPad App
7. 选择 `Direct`
8. 在地址栏输入以下任一形式：
   - `100.x.y.z:7860`
   - `http://100.x.y.z:7860`
   - 你的 Tailscale MagicDNS 主机名
9. 输入配对码

建议额外验证：

```bash
tailscale ping <你的iPhone或iPad设备名>
```

如何理解结果：

- `direct`：最好
- `DERP` / relay：能用，但远程延迟通常会更高

什么时候该选 Direct：

- 你要远程，而且很在意延迟
- 你不想暴露公网域名
- 你的手机 / 平板允许安装 Tailscale

Direct 排错建议：

- 如果 bridge 日志显示很快收到回复，但手机展示仍然慢，先检查 `tailscale ping` 是不是走了 relay
- 如果你开着 Clash 一类代理，建议把 `100.64.0.0/10` 排除代理
- 如果 App 明明输入了 `http://100.x.y.z:7860` 却配不上，确认你装的是包含当前 ATS 配置的最新构建

### 方式三：Cloudflare

适合谁：

- 你需要从任意公网网络访问
- 你不方便在所有客户端上装 Tailscale
- 你希望通过域名 + HTTPS 暴露 bridge

代价：

- 一般延迟高于 `Direct`
- 像 SSE 这种长连接式交互，有时稳定性和实时性不如私网直连
- 如果你追求 1 秒内交互体验，通常优先试 `Direct`

#### Cloudflare 部署步骤

1. 准备一个 Cloudflare 账号
2. 安装 `cloudflared`
   - 官方下载：https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
   - Homebrew：`brew install cloudflared`
3. 先登录一次：

```bash
cloudflared tunnel login
```

4. 创建一个命名 tunnel：

```bash
cloudflared tunnel create agent-watcher
```

5. 把域名指向 tunnel：

```bash
cloudflared tunnel route dns agent-watcher bridge.example.com
```

6. 创建 `~/.cloudflared/config.yml`：

```yaml
tunnel: YOUR_TUNNEL_ID
credentials-file: /Users/your-name/.cloudflared/YOUR_TUNNEL_ID.json

ingress:
  - hostname: bridge.example.com
    service: http://localhost:7860
  - service: http_status:404
```

7. 在本地启动 bridge：

```bash
node skill/bridge/server.js --pairing-code 123456
```

8. 启动 Cloudflare tunnel：

```bash
cloudflared tunnel run agent-watcher
```

9. 在 iPhone / iPad App 中：
   - 选择 `Cloudflare`
   - 输入 `https://bridge.example.com`
   - 如果你给域名加了 Cloudflare Access，还要再填：
     - `CF-Access-Client-Id`
     - `CF-Access-Client-Secret`
   - 再输入 6 位配对码

#### 建议同时开启 Cloudflare Access

如果你不希望这个 bridge 域名裸露给公网：

1. 打开 Cloudflare Zero Trust
2. 新建一个 self-hosted application，保护 `bridge.example.com`
3. 在 `Access > Service Auth` 下创建 Service Token
4. 把生成出来的 client ID / client secret 填进 App

什么时候该选 Cloudflare：

- 你必须从公网任意地方访问
- 你没法在客户端装 Tailscale
- 你接受延迟高于 Direct

Cloudflare 排错建议：

- 先用 `http://127.0.0.1:7860/status` 验证 bridge 本地本身没问题
- 日常使用建议优先命名 tunnel，不要依赖临时 quick tunnel
- 如果审批或流式输出明显卡顿，先切回 `Direct` 做对比，不要先怀疑 bridge 审批逻辑

## 审批与 Session 语义说明

这个项目很重要的一点是：

- 审批会绑定到正确的 session
- session 归属不会因为 `LAN / Direct / Cloudflare` 而变化
- iPhone、iPad、Apple Watch 都是消费同一份 bridge 真相
- 网络模式只决定“怎么连上 bridge”，不决定“这个审批是谁的”

## 目录结构

```text
claude-watch/
├── skill/
│   ├── bridge/server.js
│   ├── setup-hooks.sh
│   └── setup.sh
├── ios/ClaudeWatch/
│   ├── project.yml
│   ├── ClaudeWatch iOS/
│   ├── ClaudeWatch iPad/
│   ├── ClaudeWatch watchOS/
│   └── Shared/
└── README.md
```

## 日常使用流程

1. 在 Mac 上启动 bridge：`node skill/bridge/server.js`
2. 在 Mac 上启动 agent，推荐放 tmux 里跑：
   - `tmux new -s dev && claude-watch`（或 `codex-watch`）
   - 也可以不在 Mac 上开，后面通过手机 `+` 按钮远程新开
3. 打开 iPhone App，用 6 位配对码完成配对
4. 在手机、iPad 或手表查看当前 session
5. 有审批时直接远程处理
6. 需要时在手表语音发一句跟进提示词，或者在手机 / iPad 输入

## 作者

作者：Hanmin Wang

当前工作区使用的 GitHub 账号：

- https://github.com/Miraclemin

## 开源协议

本项目使用 MIT License，详见 [LICENSE](./LICENSE)。
