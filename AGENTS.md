# Agents

This repo is the **tool**: a signed `.app` + MCP (`computer-use`) so chats can see and click macOS GUIs. **DESIGN.md** is tool principles, primitives, and macOS facts. **`.agents/skills/computer-use/SKILL.md`** restates that for agents using the MCP. `README.md` is the human intro / setup.

The helper’s default click/type/scroll path avoids capturing the editor, the keyboard, or the current Space (Codex shows that is enough for almost all drive). That is a **tool** goal. Do not encode it as “agents must never open an app or raise a window.” The agent is not the tool.

## Hard rules (changing this repo)

- Do not call or patch `Codex Computer Use.app` / `@oai/sky`. Match their *drive primitives* (AX + screenshot, `element_index`, pid-directed input, no off-Space HID). Extras we skip and why: **DESIGN.md** (Codex parity) — do not add `paste`, auto-launch, AX diffs, auto-skyshot, PIP, lock-screen, or a start/stop session.
- Do not put `open -a` / `activate` / `AXRaise` on the default observe or click path in the helper. `isolate_window` is the explicit raise primitive. Do not grant Accessibility to the editor that hosts the chat.
- Sign with Developer ID via `./build.sh`. Never ad-hoc. One resident helper; do not spam `open -n`. Identity (bundle id, app name, codesign) lives in **`config.local`** (gitignored). Do not put home paths or Developer ID names in tracked files.
- This stack is pixels and the accessibility tree. GPU views often have an empty tree; the screenshot is then the source of truth.
- When **testing the tool**, prove AX/pid against a window that is already open (possibly another Space). That verifies the primitive. An agent with a real task may still launch Settings, raise, etc.

After a behavior change in the helper, update DESIGN (why the primitive looks like that) and the skill (how an agent should understand it).

## Reloading the MCP

Clients cache the `computer-use` tool list. After changing tools or the helper, reload it yourself.

1. If names or schemas changed: `python3 server.py --tools > tools.json` (`mcp.mjs` reads that file once per process).
2. Restart the HTTP server: `launchctl kickstart -k "gui/$(id -u)/$LAUNCHD_LABEL"` (`LAUNCHD_LABEL` from `config.local`, default `$BUNDLE_ID.mcp`).
3. Reconnect the client so it fetches the new list. A client that stores the server in a config file needs that entry removed, saved, and put back. For Cursor that file is `~/.cursor/mcp.json`:
   ```json
   "computer-use": { "type": "http", "url": "http://127.0.0.1:8765/mcp" }
   ```

Confirm against the **live** server (`tools/list` on `http://127.0.0.1:8765/mcp` with an MCP session), not an already-open chat’s tool snapshot. An open conversation can keep listing old names after a bounce; calls still hit `:8765`. A new chat picks up the refreshed list.
