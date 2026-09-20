# Computer use

Want an agent on **macOS** to use a real GUI — Mail, Finder, System Settings, Safari, an editor, anything on screen — the way you would: look at the window, click a control, type.

Most “computer use” products either live inside one chat app (OpenAI’s Codex Computer Use only runs under ChatGPT), or they drive the Mac by moving **your** mouse and bringing windows forward (which steals the Space you are on). This repo is an MCP server backed by a **signed macOS .app** that sees a window (screenshot + accessibility tree) and clicks it **in that app’s process**, including windows on another Space. Your pointer stays put. The window does not come forward unless you ask (`isolate_window`).

Any MCP client can use it (Cursor, Claude Code, …). It is not a ChatGPT plugin; if you already use Codex Computer Use, keep that.

## Install

Needs macOS 14+, Python 3, Node, and a **Developer ID** (or Apple Development) identity in the keychain. Ad-hoc signing breaks Accessibility on every rebuild; `build.sh` will not do it.

```sh
git clone <this-repo>
cd <folder>
cp config.example config.local
```

In `config.local`, set `BUNDLE_ID` (keep it stable) and `CODESIGN_IDENTITY` (`security find-identity -v -p codesigning` prints the `Developer ID Application: Name (TEAMID)` string). Then:

```sh
./setup.sh
```

That builds the app, starts a helper, and serves MCP at `http://127.0.0.1:8765/mcp`. macOS will open Accessibility and Screen Recording — enable **this signed app** in both (Sequoia’s Accessibility sheet has no in-dialog Allow). Grant those to the helper, not to your editor.

Add to your MCP client:

```json
"computer-use": { "type": "http", "url": "http://127.0.0.1:8765/mcp" }
```

Later rebuilds: `./build.sh`. Changing `BUNDLE_ID` means granting TCC again.

## How it works

Typical call: `get_app_state` for a window, then `click` / `scroll` / `type_text` by `element_index` from the tree. `scroll` always needs that index. There is no lock-screen, PIP, or virtual cursor.

macOS binds Accessibility and Screen Recording to the **signed .app**. `setup.sh` writes a LaunchAgent into `~/Library/LaunchAgents` so MCP stays up at `:8765` (`mcp.mjs` → `server.py` → a unix socket → the helper). The `.app` itself is a build artifact (gitignored). Identity lives in `config.local`.

| Pane                                                 | Need     |
| ---------------------------------------------------- | -------- |
| Accessibilité                                        | Required |
| Enregistrement de l’écran                            | Required |
| Automatisation / Input Monitoring / Full Disk Access | Not used |

## Project layout

| Path                                         | Role                                           |
| -------------------------------------------- | ---------------------------------------------- |
| `DESIGN.md`                                  | Drive model, macOS facts, Codex parity         |
| `AGENTS.md`                                  | Rules for changing this repo                   |
| `.agents/skills/computer-use/SKILL.md`       | How an agent should use the MCP                |
| `helper.swift` / `mcp_server.swift`          | Capture, AX, clicks, keys; LaunchAgent wrapper |
| `server.py` / `mcp.mjs` / `tools.json`       | MCP tools → unix socket → helper               |
| `config.example`                             | Template for gitignored `config.local`         |
| `Info.plist.in` / `mcp_server-Info.plist.in` | Filled at build from `config.local`            |
| `build.sh` / `setup.sh`                      | Sign, generate LaunchAgent, open TCC panes     |
| `icons/`                                     | Source art (`ICON_SRC` to pick one at build)   |
