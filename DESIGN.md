# Design: computer-use

This file is the **tool**: primitives, why they are implemented this way, and macOS facts that constrain them. Setup / TCC / layout: `README.md`. What an agent should know to *use* the MCP: `.agents/skills/computer-use/SKILL.md`.

The agent is not the tool. “Do not capture Cursor / the keyboard / the current Space” is an **implementation** goal for these primitives (Codex shows most drive does not need capture). It is not a rule that chats must never open an app or switch Spaces.

## Goal

Give MCP agents a Codex-like see/click loop on macOS: screenshot + accessibility tree, drive by control index. TCC on a signed `.app`, not on the chat client.

| Build | Do not build |
|---|---|
| Flexible primitives: list, screenshot+tree, click/type/scroll/keys | Cursor Cloud computer-use; calling or patching `Codex Computer Use.app` |
| Default paths that do **not** go through Cursor.app, HID, or Mission Control | Virtual cursor, PIP, lock-screen CU, record/replay, Skysight |
| Accessibility + Screen Recording on **this signed .app** | Granting Accessibility to Cursor.app |
| `isolate_window` as an explicit raise/fullscreen primitive | System Events / AppleScript GUI scripting; wrapping `open -a` (the shell already does that) |

Unreal **MCP** edits the scene. This stack is pixels and the accessibility tree. GPU views often have an empty tree — then the JPEG is the source of truth.

## Agent vs tool

| | Tool (helper / MCP) | Agent (task + skill) |
|---|---|---|
| Window is already open, maybe another Space | Screenshot by window id; click/type via accessibility or pid | Use those primitives; no need to raise |
| Window is not open | No launch-app tool | `open -g -a "App"` to start without activating; `open -a` if you want it front (may switch Space) |
| Need the app actually front | `isolate_window` (will come forward; may change Space) | Call it when the task needs a front window, not as politeness |
| Real mouse on this display | HID, and only if that window is on this Space (otherwise it hits Cursor) | Prefer `element_index`; HID is the wrong primitive off-Space |

## Approach

### Process identity

macOS TCC (Accessibilité, Enregistrement de l’écran) attaches to a **signed .app**, not to a random `helper` binary and not to Cursor.

```
Cursor  --HTTP :8765-->  MCP server binary (LaunchAgent, inside the signed .app)
                              --> node mcp.mjs --> server.py
                                                    --> unix socket
                                                          --> helper executable
                                                                (inside the .app)
```

- Bundle ID and display name come from **`config.local`** (copy `config.example`). Never ad-hoc sign: cdhash change drops Accessibility.
- One resident helper (`open -a`, unix socket). `open -n` **per click** re-prompts Sequoia; that is why serve stays resident.
- Observe tools do not `NSRunningApplication.activate`. Click/type/scroll do not need a start/stop session: AX and `postToPid` work without one. Codex’s session is lock-screen / sleep / PIP — extras we do not want. We do **not** remember a restore app at “session start” and `activate` it after each click (that yanked the user back to that Space).

### Drive model (why the helper prefers this order)

Match Codex Sky’s *window* API, not their extras. Each step is a primitive that usually works **without** making that app key on this Space:

1. **Accessibility index** — `AXPress` / `AXFocused` / `set_value` / `AXSelectedRows` / named actions. Works on background apps; does not move the real pointer.
2. **Accessibility scroll** — `scroll({ element_index, direction, pages })` on that node (or its nearest scroll area / outline / web area). Page actions if they actually move, else that container’s scrollbar `AXValue`. Pid-wheel only if the AX fingerprint (scrollbar or children) changed. No window-guess HID. `AXScrollToVisible` is a per-element secondary action, not this pager. `click` may `AXScrollToVisible` first if the control’s frame is outside the window.
3. **Synthetic key for `--wid`** — Codex-style `NSEventTypeAppKitDefined` plus yabai `SLPSPostEventRecordTo`, posted to the pid. **Not** `_SLPSSetFrontProcessWithOptions` (that steals the keyboard even with `kCPSNoWindows`). No undo-if-front-changed: Mail dump/click/type did not flip Space on this path, and restoring whoever was front fights a user who switched during the call.
4. **Pid-directed CGEvent** — unicode typing, coordinate click/wheel, stamped with the CG window id.
5. **HID** (`cghidEventTap`) — real pointer, **only** if the target window is on this Space. Off-Space HID would click Cursor.
6. **`isolate_window`** — raise / fullscreen, and **leave it front**. The capture primitive; keep it out of the default click path.

`type_text` is unicode key events to that pid (optional index to focus first). Native fields can also use `set_value`. After a successful `AXPress`, do not also pid-click that control’s screen point (those coordinates often sit on this Space).

### Window identity

A screenshot is a **CG window** (`CGWindowID`, bounds, `on_screen` via ScreenCaptureKit). An AX dump is an **AX window** of that pid. They are not the same list.

Picker order: CG window id (`_AXUIElementGetWindow`) → normalized title → bounds. Never silently dump Mail’s focused compose when the screenshot was Envoyés.

## macOS facts (constrain the tool)

`activate` / `open -a` / `AXRaise` bring that app’s Space forward. The helper’s default click path must not do those. `open -g -a` launches without activating.

A window with `on_screen: false` is on another Space (or fully occluded). Screenshot by window id still works. HID at those coordinates does not — it hits this Space.

New windows usually appear on the **current** Space (Mail compose, a Settings window you just launched). That is WindowServer. Do not add Space-move APIs to the helper; recapture the new window.

| | CoreGraphics / SCK | Accessibility |
|---|---|---|
| Lists | All windows, including other Spaces | What that **pid** publishes |
| Stable id | `CGWindowID` | `AXUIElement` (Codex uses `_AXUIElementGetWindow`) |
| Titles | Window name | Often longer, or changes after `set_value` |

Mail only publishes the key/focused window on `AXWindows` until we synthetically key `--wid`. Then Inbox/Envoyés dump that window even if a compose exists elsewhere.

**Menus, sheets, popovers** are overlay windows (CG layer > 0). `list_apps` skips those layers, so the parent can stay `on_screen: false` while `AXPress` on a popup still draws the menu on **this** Space. That is WindowServer. Pid-clicking that overlay’s screen rect aims at pixels the user is looking at and often beeps — hence “AXPress succeeded → do not pid-click.”

- HID: process-wide tap, window under the real cursor.
- `postToPid`: that process only; it still chooses which of its windows is key.
- Stamping `kCGMouseEventWindowUnderMousePointer` is how Codex aims at a `CGWindowID`. Necessary, not always enough (Mail list / body).

TCC must name **this signed .app** (Developer ID from `config.local`). Cursor as parent of an unsigned helper is how we prompted for Cursor.app — refuse that sheet.

## Current gaps

- Mail, proven without raising Inbox’s Space: tree includes toolbar **Nouveau message**; list select via `AXSelectedRows`; list scroll via scrollbar `AXValue` on the outline’s container (`scroll` requires that `element_index`); compose body `type_text` into the web area; headers `set_value`; discard sheet `AXPress`. Compose still births on the current Space — expected.
- Closing an **off-Space fullscreen unsaved compose** still brings that Space forward (AppKit save sheet). Windowed compose on this Space does not.
- Mail list pid-wheel / pid-click often no-ops; `AXScrollDownByPage` often `kAXErrorCannotComplete`. Scrollbar `AXValue` moves pixels. `scroll` without `element_index` is rejected; pid-wheel is not reported `ok` unless children/scrollbar actually moved.
- WebKit (Safari/Google): pid-wheel still does not page the document. If Safari exposes a window `AXScrollBar`, `scroll` on that scroll area/`element_index` moves via `AXValue` (verified on Forums). `AXScrollToVisible` on a descendant remains the “bring this result into view” action.
- Off-Space popup menus still paint on the active Space. Helper no longer pid-clicks after `AXPress`; opening the menu still flashes.
- No MCP `launch_app`: use the shell.

## Key-window (landed)

Given `--wid`, `ensureSyntheticKey` posts AppKitDefined subtype 1 / key-focus plus yabai make-key records to the pid. It does **not** SetFrontProcess, and it does not `activate` anyone afterwards.

## Codex parity

`~/.codex/computer-use/Codex Computer Use.app` and ChatGPT’s `@oai/sky` are a **behavior spec** for drive primitives, never a library from Cursor. Match their window API (AX + screenshot, `element_index`, pid-directed input, no off-Space HID). Do not copy isolation extras or loop sugar.

### Shared drive tools

| Codex | Us | Notes |
|---|---|---|
| `list_apps` | Windows + `on_screen` | They list **apps** (running + 14-day usage). We list **windows** so Mail inbox vs compose and other Spaces are distinct. |
| `get_app_state` | One CG window, full tree + JPEG, no raise | They take the app’s key window, may auto-launch, optional AX diff. We pick by substring / last window. |
| `click` | Index or screenshot x,y | AXPress first; `AXScrollToVisible` if the frame is outside the window; no pid-click after a successful press (overlay coords sit on this Space). |
| `scroll` | Requires `element_index` + direction + pages | Ancestor scroll area; AX page then scrollbar `AXValue`; pid-wheel only if something moved. No window-guess. |
| `drag` | Screenshot coords, posted to the pid | Same idea as their synthesized-in-window drag. |
| `set_value` | AX value on an index | They also have `autosubmitSearchFields` — skip. |
| `perform_secondary_action` | Named AX action | We block `AXRaise` (use `isolate_window`). |
| `type_text` | Unicode keys to that pid | Optional index to focus first. Not clipboard paste. |
| `press_key` | Pid-directed, `cmd`/`super` | xdotool-style. |
| *(PIP / session raise)* | `isolate_window` | Explicit raise/fullscreen; leaves the app front. Not on the default click path. |

### Intentionally not copied

| Codex | Why we skip it |
|---|---|
| `paste` (clipboard + restore, text/md/html) | Fights the user’s clipboard; more focus-sensitive than `set_value`. Bulk insert stays `type_text` / `set_value`. |
| `select_text` (match in a field; prefix/suffix; caret before/after) | Skip for now. The agent can `set_value` the whole field (or click + `type_text` after selecting all). Not optimal for a mid-string edit, but workable. Native `AXSelectedTextRange` would be the later upgrade; WebKit/Mail body often have no settable range anyway. |
| Auto-launch from `get_app_state` | `open -a` activates and can switch Spaces. Observe must not launch. Agent uses `open -g -a` when the window is missing. |
| Wait / skyshot after every action (`waitForUIToSettle`, `returnSkyshot`) | Folds recapture into click/type (one less round trip, extra sleep + JPEG even when nothing changed). Agent calls `get_app_state` when the UI changed. |
| AX diffs (`disableDiff`) | Token saver, same tree. Stale indexes if the client applies the delta wrong. We always send the full dump + JPEG. |
| Start/stop drive session | That session is lock-screen / sleep / PIP. We copied a restore-front wrapper without those extras; it yanked the user back to the Space captured at “start.” Removed. |
| PIP, virtual/fog cursor, lock-screen CU | Isolation products. We drive the real window off-Space instead. |
| Record/replay, Skysight, confirmation policy | Around the app, not drive primitives. |
