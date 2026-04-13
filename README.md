<p align="center">
  <a href="./README.zh-CN.md">简体中文</a> | <strong>English</strong>
</p>

<p align="center">
  <img src="./ios/ClaudeWatch/ClaudeWatch%20iOS/Assets.xcassets/AppLogo.imageset/1.png" width="160" alt="Agent Watcher logo" />
</p>

<h1 align="center">Agent Watcher</h1>

<p align="center">
  Turn Claude Code and Codex on your Mac into a wrist-first, phone-friendly remote workspace.
  <br />
  Read live output, answer approvals, and send voice prompts from Apple Watch, iPhone, and iPad.
</p>

## What This Project Is For

Agent Watcher is designed for people who run AI coding agents on a Mac but do not want to stay in front of the computer all the time.

Typical scenarios:

- You are walking, commuting, or away from your desk and need to approve an agent action immediately.
- You want to check whether Claude Code or Codex is still running, waiting, or finished.
- You want to send a short follow-up prompt from your watch or phone without opening the Mac.
- You want one bridge that works on local Wi-Fi, a private remote network, and a public remote tunnel.

The project keeps the same approval flow and session ownership semantics across all transport modes. `LAN`, `Direct`, and `Cloudflare` only change how the client reaches the bridge. They do not redefine which session an approval belongs to.

## Main Features

- Apple Watch approval handling for Claude Code and Codex sessions
- Apple Watch voice input for quick follow-up prompts
- iPhone companion app for pairing, transport selection, status, terminal stream, and approvals
- iPad companion app with the same approval and session-routing logic as iPhone
- Multi-session bridge on macOS for Claude Code, Codex, tmux-backed sessions, and mirrored external terminals
- Persistent 6-digit pairing code support
- Three network entry modes:
  - `LAN` for the same Wi-Fi / office network
  - `Direct` for private networking such as Tailscale
  - `Cloudflare` for public HTTPS access over the Internet

## Architecture

```text
Apple Watch  <--WCSession-->  iPhone / iPad  <--HTTP / SSE-->  Bridge Server on Mac
                                                                  |
                                                                  +--> Claude Code
                                                                  +--> Codex
                                                                  +--> tmux / mirrored terminals
```

## Transport Modes

| Mode | Best for | Latency | Internet exposure | Notes |
| --- | --- | --- | --- | --- |
| `LAN` | Same home/office Wi-Fi | Lowest | No | Easiest local setup |
| `Direct` | Remote access with low latency | Usually best remote option | No | Recommended with Tailscale |
| `Cloudflare` | Reach from anywhere without VPN | Usually higher than Direct | Yes, via Cloudflare | Best when you need public HTTPS |

## Downloads And Prerequisites

You need the following tools before building or deploying:

- Node.js 18+:
  - Download: https://nodejs.org/en/download
- Xcode:
  - Download: https://developer.apple.com/xcode/
  - App Store page: https://apps.apple.com/us/app/xcode/id497799835
- XcodeGen:
  - Download / releases: https://github.com/yonaskolb/XcodeGen/releases
  - Homebrew: `brew install xcodegen`
- Optional for `Direct` mode:
  - Tailscale: https://tailscale.com/download
- Optional for `Cloudflare` mode:
  - cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/

Hardware / platform assumptions:

- A Mac running Claude Code or Codex
- An iPhone paired with an Apple Watch if you want watch approval / voice control
- An optional iPad if you want a larger remote control surface

## Release Assets

This repository can ship three built app bundles as GitHub Release assets:

- `Agent Watcher.app` for iPhone
- `Agent Watcher Pad.app` for iPad
- `Agent Watcher.app` for watchOS

Important:

- These builds are development artifacts. Real-device installation still depends on Apple signing and Developer Mode.
- For most users, the most reliable installation path is to build from source in Xcode with your own Apple ID / team selected.

## Quick Start

### 1. Clone the repository

```bash
git clone <your-repo-url>
cd claude-watch
```

### 2. Install bridge dependencies

```bash
./skill/setup.sh
```

Or manually:

```bash
cd skill/bridge
npm install
```

### 3. Install Claude Code hooks

```bash
./skill/setup-hooks.sh
```

If your bridge runs on a different local port:

```bash
./skill/setup-hooks.sh 7860
```

To remove hooks later:

```bash
./skill/setup-hooks.sh --remove
```

### 4. Start the bridge

Auto-generate a pairing code for this bridge process:

```bash
node skill/bridge/server.js
```

Or define a fixed pairing code that never changes until you restart with a different one:

```bash
node skill/bridge/server.js --pairing-code 123456
```

Environment variable form:

```bash
PAIRING_CODE=123456 node skill/bridge/server.js
```

The bridge prints:

- Pairing code
- IP address
- Port

The pairing code is reusable:

- It is not consumed by the first device
- It does not expire automatically while the bridge keeps running
- One code can pair multiple iPhones / iPads / Watches

### 5. Build the apps

```bash
cd ios/ClaudeWatch
xcodegen generate
open ClaudeWatch.xcodeproj
```

Build targets:

- `ClaudeWatch`: iPhone app with embedded Apple Watch companion
- `ClaudeWatchPad`: iPad app
- `ClaudeWatchWatch`: watch target if you need to run watchOS directly

## First-Time Xcode And Device Setup

This section is written for someone who has never deployed an iPhone / Watch app before.

### 1. Install Xcode and open it once

- Download Xcode from Apple.
- Open Xcode and let it finish installing additional components if prompted.
- Sign in with your Apple ID in `Xcode > Settings > Accounts`.
- If Apple shows a developer agreement, accept it before continuing.

### 2. Connect your devices to Xcode

- Connect your iPhone to the Mac.
- Unlock the iPhone and tap `Trust This Computer` if prompted.
- Open `Window > Devices and Simulators` in Xcode and confirm the iPhone appears.
- If you use Apple Watch, make sure the watch is paired to that iPhone.

Apple notes that the watch becomes available to Xcode through the paired iPhone, and Developer Mode must be enabled on the watch too.

### 3. Enable Developer Mode

Developer Mode is required for running development-signed apps from Xcode.

On iPhone / iPad:

1. In Xcode, choose your real device as the run destination and press `Run` once.
2. If Xcode says Developer Mode is required, cancel the run.
3. On the device, open `Settings > Privacy & Security > Developer Mode`.
4. Turn it on.
5. Restart when prompted.
6. After reboot, unlock the device and confirm `Enable Developer Mode`.

On Apple Watch:

1. Try to run the watch target from Xcode once.
2. On the watch, open `Settings > Privacy & Security > Developer Mode`.
3. Turn it on and confirm after restart if prompted.

### 4. Configure signing

In Xcode, open the `Signing & Capabilities` tab for each target and select your team:

- `ClaudeWatch`
- `ClaudeWatchWatch`
- `ClaudeWatchPad`

The current bundle IDs in this project are:

- iPhone: `com.nightwatcherphone.han`
- Watch: `com.nightwatcherphone.han.watchkitapp`
- iPad: `com.han.agentwatch.ipad`

If Xcode shows provisioning issues:

- Re-select your team
- Let Xcode manage signing automatically
- Try `Product > Clean Build Folder`

### 5. Run the apps

iPhone + Apple Watch:

1. Select the `ClaudeWatch` scheme.
2. Choose the connected iPhone as the run destination.
3. Press `Run`.
4. Xcode installs the iPhone app and the embedded watch app.

iPad:

1. Select the `ClaudeWatchPad` scheme.
2. Choose the connected iPad as the run destination.
3. Press `Run`.

## Pairing Flow

The app home screen lets you choose one of three connection modes before entering the pairing code:

- `Local`
- `Direct`
- `Cloudflare`

General pairing flow:

1. Start the bridge on the Mac.
2. Read the 6-digit pairing code from the bridge banner.
3. Open the iPhone or iPad app.
4. Choose the transport mode.
5. Enter the address if that mode requires one.
6. Enter the pairing code.
7. After the phone is paired, the watch should receive bridge credentials from the phone automatically.

If the watch is still waiting after the phone is paired, reopen the watch app and let it sync once more.

## Deployment Guide By Mode

### Mode 1: LAN

Best for:

- Working at home or in the office
- Mac, iPhone, and watch on the same Wi-Fi
- Lowest complexity and lowest local latency

What you need:

- Mac and iPhone on the same network
- Bridge running on the Mac
- Apple Watch ideally on the same Bonjour-compatible Wi-Fi if you expect local discovery behavior to be reliable

Steps:

1. Start the bridge:

```bash
node skill/bridge/server.js --pairing-code 123456
```

2. Open the iPhone app.
3. Choose `Local`.
4. Leave the address blank for auto-discovery, or enter the Mac's LAN IP manually, for example:

```text
192.168.1.21
```

5. Enter the 6-digit pairing code.
6. Wait for the status screen to show the active sessions.
7. Open the watch app and confirm the watch leaves the waiting screen.

Use LAN when:

- You are physically near the Mac
- You do not need remote access over the Internet
- You want the most straightforward setup

Troubleshooting:

- If auto-discovery fails, enter the LAN IP manually.
- If the phone can reach `/status` in Safari but pairing fails, confirm the pairing code matches the currently running bridge.
- If the watch cannot sync, first pair the phone successfully, then reopen the watch app.

### Mode 2: Direct

Best for:

- Remote work over a private network
- Low-latency control without publishing the bridge to the public Internet
- The recommended remote mode for day-to-day use

Typical implementation:

- Tailscale

Why this mode is recommended:

- The bridge protocol, approvals, and session ownership logic remain unchanged.
- Only the network path changes.
- In the best case, Tailscale uses a direct private path instead of an HTTP proxy.

#### Direct mode setup with Tailscale

1. Install Tailscale on the Mac:
   - https://tailscale.com/download
2. Install Tailscale on the iPhone / iPad:
   - use the same Tailscale download page or the App Store listing linked from there
3. Log in to the same tailnet on both devices.
4. On the Mac, verify the private IP:

```bash
tailscale ip -4
```

Example:

```text
100.104.162.41
```

5. Start the bridge:

```bash
node skill/bridge/server.js --pairing-code 123456
```

6. Open the iPhone or iPad app.
7. Choose `Direct`.
8. Enter one of the following:
   - `100.x.y.z:7860`
   - `http://100.x.y.z:7860`
   - your Tailscale MagicDNS host if you use one
9. Enter the pairing code.

Recommended validation:

```bash
tailscale ping <iphone-or-ipad-device-name>
```

Interpretation:

- `direct` is ideal
- `DERP` / relay works, but latency will usually be higher

Use Direct when:

- You want the best remote latency
- You do not want the bridge to be publicly reachable
- You can install Tailscale on both sides

Direct mode troubleshooting:

- If you see good local bridge logs but slow mobile delivery, check whether `tailscale ping` is using relay instead of direct.
- If you use a VPN / proxy app such as Clash, exclude the Tailscale subnet `100.64.0.0/10` from proxying.
- If the app rejects plain `http://100.x.y.z:7860`, rebuild with the current project settings so the bundled ATS exceptions are present.

### Mode 3: Cloudflare

Best for:

- Public remote access from anywhere
- Situations where you cannot install Tailscale on every client
- A setup where HTTPS and a domain name are preferred

Tradeoffs:

- Usually slower than `Direct`
- Long-lived interactive flows such as SSE can be less stable than a private direct path
- Recommended only when public remote access matters more than lowest latency

#### Cloudflare setup

1. Create or use an existing Cloudflare account.
2. Install `cloudflared`:
   - official downloads: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
   - Homebrew: `brew install cloudflared`
3. Authenticate once:

```bash
cloudflared tunnel login
```

4. Create a named tunnel:

```bash
cloudflared tunnel create agent-watcher
```

5. Route a hostname to the tunnel:

```bash
cloudflared tunnel route dns agent-watcher bridge.example.com
```

6. Create `~/.cloudflared/config.yml`:

```yaml
tunnel: YOUR_TUNNEL_ID
credentials-file: /Users/your-name/.cloudflared/YOUR_TUNNEL_ID.json

ingress:
  - hostname: bridge.example.com
    service: http://localhost:7860
  - service: http_status:404
```

7. Start the local bridge:

```bash
node skill/bridge/server.js --pairing-code 123456
```

8. Start the Cloudflare tunnel:

```bash
cloudflared tunnel run agent-watcher
```

9. In the iPhone or iPad app:
   - choose `Cloudflare`
   - enter `https://bridge.example.com`
   - if protected by Cloudflare Access, also enter:
     - `CF-Access-Client-Id`
     - `CF-Access-Client-Secret`
   - enter the 6-digit pairing code

#### Optional but recommended: Cloudflare Access

If you do not want the bridge domain to be openly reachable:

1. Open Cloudflare Zero Trust.
2. Create a self-hosted application for `bridge.example.com`.
3. Create a Service Token under `Access > Service Auth`.
4. Copy the client ID and client secret into the app's Cloudflare fields.

Use Cloudflare when:

- You need reachability from arbitrary networks
- VPN installation is not possible
- You accept higher latency than a private direct path

Cloudflare troubleshooting:

- If requests randomly stall or disconnect, test the bridge locally first with `http://127.0.0.1:7860/status`.
- Prefer a named tunnel over an ad-hoc quick tunnel for day-to-day use.
- If approval screens or streaming feel delayed, test `Direct` mode before changing bridge logic.

## How Approvals And Sessions Behave

This point matters for this project:

- Approvals are bound to the correct session by the bridge and shared client state
- Session ownership does not change when you switch between `LAN`, `Direct`, and `Cloudflare`
- iPhone, iPad, and Apple Watch all consume the same bridge truth; transport mode only changes network reachability

## Project Structure

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
└── README.zh-CN.md
```

## Common Usage Flow

1. Start the bridge on the Mac.
2. Start Claude Code or Codex on the Mac.
3. Open the iPhone app.
4. Pair once with the 6-digit code.
5. Check the current session on phone or watch.
6. Approve or deny actions remotely when needed.
7. Dictate a short follow-up prompt from the watch or type from phone / iPad.

## Author

Created and maintained by Hanmin Wang.

GitHub profile used in the current workspace:

- https://github.com/Miraclemin

## Credits

This project is independently maintained by Hanmin Wang and references the earlier `claude-watch` project for inspiration:

- https://github.com/shobhit99/claude-watch

## License

This project is released under the MIT License. See [LICENSE](./LICENSE).
