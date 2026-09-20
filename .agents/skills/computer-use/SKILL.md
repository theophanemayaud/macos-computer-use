---
name: computer-use
description: Operate a macOS GUI via the computer-use MCP.
---

# computer-use

MCP `computer-use` talks to a **signed helper .app** on macOS. It is a set of primitives for looking at and driving windows. How you use them depends on the task (including launching an app if the window is not there). The helper is built so **most** click/type/scroll paths do not bring that app forward, move the mouse, or switch Spaces — same idea as Codex Computer Use.

## Tools


| Tool                                                                                      | What it is for                                                                                   |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `list_apps`                                                                               | Windows, including other Spaces. `on_screen: false` = other Space or fully covered               |
| `get_app_state`                                                                           | Picture + numbered controls for one window (`app` = owner or title substring). Does not raise it |
| `click` / `scroll` / `type_text` / `press_key` / `set_value` / `perform_secondary_action` | Drive that window. Prefer `element_index` from the last tree. No start/stop session              |
| `isolate_window`                                                                          | Raise or fullscreen. This **does** come to the front and may change Space; it stays front        |


There is no launch-app tool. If nothing is running, `open -g -a "App Name"` starts it **without** bringing it forward (you stay on this Space). Plain `open -a` activates the app and macOS will switch to that app’s Space if it already has a window there.

## A typical loop

1. `list_apps` if you need to see what exists.
2. `get_app_state` for the window you will drive.
3. Act by `element_index`. Recapture when the UI changed.

Screenshot x,y is posted to that app (not a real mouse move) when the window is off this Space. A real pointer click is only used if the window is actually on this Space — otherwise it would hit whatever you are looking at.

## Facts that change which primitive you pick

- **Two lists.** The picture is a window id; the tree is what that app exposes. Recapture the window you mean.
- **New windows appear on the current Space.** Drive that window or close it.
- **List rows** often have no button action. Selecting the row is what works.
- `scroll` **needs** `element_index` (the list, scroll area, web area, or a row inside it). If paging cannot move the view, `perform_secondary_action` `AXScrollToVisible` brings a node already in the tree into sight.
- **Text:** `set_value` for real fields. For a web area, click it then `type_text`.
- **Popup menus** draw on the Space you are looking at, even if the parent window is elsewhere. Opening one is visible here. After `AXPress` on a popup, pick the item **before** the next `get_app_state` — a recapture closes the menu.
- A **black picture** usually means you captured a helper process, not the window that painted. Recapture the host window.

Accessibilité and screen recording belong to **the signed helper .app**, not the chat app or IDE. Decline a sheet for those. Do not call Codex Computer Use from this stack. Scene edits in Unreal: Unreal MCP; this MCP is the editor window’s pixels and tree.
