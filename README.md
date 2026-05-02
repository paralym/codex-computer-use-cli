# Codex Computer Use CLI

A Swift CLI tool that replicates [OpenAI Codex](https://openai.com/index/introducing-codex/)'s Computer Use functionality. Operates on macOS apps via Accessibility APIs and ScreenCaptureKit — lets AI agents see and interact with any application without taking over the user's screen.

> Reverse-engineered from the Codex binary (`SkyComputerUseClient`), rebuilt from scratch in Swift.

## How it works

```
codex-cu screenshot 网易云音乐     # Capture AX tree + screenshot (zero activation)
codex-cu click 网易云音乐 193      # Single-click element 193 via AXPress (zero activation)
codex-cu click 网易云音乐 161 --count 2  # Double-click (real activation with visual masking)
codex-cu type 网易云音乐 "Hello"   # Type text into app's focused element
codex-cu key 网易云音乐 "super+c"  # Press key combination to app (xdotool syntax)
```

The tool captures a **Skyshot** (Screenshot + AX Tree) of any running app, giving AI models both visual and structural context. It then executes actions on indexed elements without stealing the user's focus.

## Click strategy (4 tiers)

| Tier | Method | Activation | Works on |
|------|--------|-----------|----------|
| 1 | `AXPress` / `AXOpen` | Zero | All apps, single click |
| 2 | AX hit-test → `AXPress` | Zero | All apps, single click |
| 3 | `CGEvent.postToPid` | Zero | Native apps |
| 4 | Real activate + visual masking | ~80ms masked | Electron apps (double-click, etc.) |

For Electron apps (VS Code, Slack, 网易云音乐, etc.) that require real `NSApp.isActive` to process HID events, Tier 4 performs an ultra-fast activation cycle:

1. Raise user's windows to `kCGPopUpMenuWindowLevel` (25) via private `CGSSetWindowLevel` API
2. `NSRunningApplication.activate()` on the target — window goes behind user's raised windows
3. Deliver click events via `CGEvent`
4. Immediately restore user's app and window levels

## Available commands

```
codex-cu permissions [--request]    # Check/request Accessibility & Screen Recording
codex-cu list-apps                  # List running apps
codex-cu launch <app>               # Launch an app
codex-cu activate <app>             # Bring app to foreground
codex-cu screenshot <app> [--output path]  # Capture Skyshot (AX tree + screenshot)
codex-cu click <app> <index|x,y> [--button left|right] [--count N]
codex-cu type <app> <text>          # Type text into app's focused element
codex-cu key <app> <spec>           # Press key to app (xdotool syntax: super+c, Return, ctrl+shift+a)
codex-cu scroll <app> <index|x,y> <up|down|left|right> [--pages N]
codex-cu drag <x1,y1> <x2,y2>      # Drag between coordinates
codex-cu set-value <app> <index> <value>  # Set element value via AX
```

## Build & run

```bash
# Requires macOS 15+ and Xcode Command Line Tools
swift build
swift run codex-cu permissions --request  # Grant Accessibility + Screen Recording
swift run codex-cu list-apps
swift run codex-cu screenshot Safari
```

## Permissions required

- **Accessibility**: Required for AX tree reading and element interaction
- **Screen Recording**: Required for screenshots via ScreenCaptureKit

Grant both in System Settings → Privacy & Security.

## Architecture

```
Sources/
├── CodexCU/                    # CLI (ArgumentParser)
│   └── main.swift
└── CodexCUCore/                # Core library
    ├── Accessibility/          # AXUIElement helpers, tree walker, node model
    ├── Apps/                   # App discovery, launch, approval store
    ├── Capture/                # ScreenCaptureKit, Skyshot (screenshot + AX tree)
    ├── Cursor/                 # AI cursor overlay (WIP)
    ├── Focus/                  # FocusEnforcer, FocusStealPreventer, SyntheticAppFocusEnforcer
    ├── Input/                  # MouseController, KeyboardController, KeySyntaxParser
    ├── Permissions/            # Permission checker
    └── Tools/                  # ToolRouter (central dispatcher)
```

## Known issues & in-progress work

### Menu bar flash on Electron double-click

When double-clicking elements in Electron apps (Tier 4), the target app is briefly activated (~80ms). User windows are raised to hide the target window, but the **menu bar may still briefly flash** to show the target app's menus before reverting.

**Root cause**: `NSRunningApplication.activate()` changes the system-level active app, which includes the menu bar. Window-level masking covers the window area but not the menu bar.

**Planned fix**: Add a fullscreen transparent overlay window at `kCGPopUpMenuWindowLevel` (25) — above the menu bar (level 24) — to mask everything during the activation cycle, matching Codex's `ComputerUseCursor` overlay approach.

### Electron coordinate offset (~14px)

AX element frames in Electron apps have a small fixed offset (~14px) from actual screen positions. Currently clicking at the AX frame center, which is close enough for most UI elements but may miss narrow targets.

**Planned fix**: Investigate Codex's exact coordinate correction or use Vision OCR to map text positions from screenshots.

### MCP Server not yet implemented

The tool currently runs as a CLI only. Phase 6 of the plan is to wrap it as an [MCP](https://modelcontextprotocol.io/) server so any AI client (Claude, GPT, etc.) can use it via the standard tool protocol.

### Other TODOs

- AI cursor overlay (`ComputerUseCursor` / `FogCursorStyle`) — visual feedback for actions
- App approval store — whitelist for automated operations
- Broader Electron app testing (Notion, Lark, Discord, etc.)
- Sound effects (optional, like Codex)

## Key technical findings from reverse-engineering Codex

| Finding | Detail |
|---------|--------|
| `SyntheticAppFocusEnforcer` | Codex's class that manages "does the target app believe it has focus" |
| `applicationBelievesItIsActive` | Boolean state tracking perceived activation |
| `clickEventTap` / `keyboardEventTap` | CGEventTap instances for event interception |
| `NSEvent.mouseEvent(windowNumber:clickCount:)` | Trusted event delivery with target window routing |
| `CGSSetWindowLevel` | Private API for cross-process window level manipulation |
| `orderFrontRegardless` | Keeps overlay on top during activation changes |
| `setIgnoresMouseEvents:` | Makes overlay click-through |
| No `CGEventPost` symbols | Codex does NOT use `CGEvent.post()` directly |
| No `_SLPSSetFrontProcessWithOptions` | CPS-level focus change alone is insufficient for Electron |

## License

MIT
