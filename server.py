#!/usr/bin/env python3
"""Stdio MCP: screenshot + click on this Mac. Not Codex Computer Use."""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any

try:
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
except Exception:
    pass
os.environ.setdefault("PYTHONUNBUFFERED", "1")

ROOT = os.path.dirname(os.path.abspath(__file__))


def _load_identity() -> dict[str, str]:
    cfg: dict[str, str] = {}
    path = os.path.join(ROOT, "config.local")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip()
                if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                    val = val[1:-1]
                cfg[key] = val
    for key in (
        "BUNDLE_ID",
        "APP_DISPLAY_NAME",
        "APP_BUNDLE",
        "EXEC",
        "SERVER_EXEC",
        "LAUNCHD_LABEL",
        "SUPPORT_DIR",
    ):
        if os.environ.get(key):
            cfg[key] = os.environ[key]
    if not cfg.get("BUNDLE_ID") or not cfg.get("APP_BUNDLE") or not cfg.get("EXEC"):
        raise RuntimeError("Missing config.local. Copy config.example to config.local.")
    cfg.setdefault("APP_DISPLAY_NAME", "cursor-desktop")
    cfg.setdefault("SERVER_EXEC", cfg["EXEC"] + "Server")
    cfg.setdefault("LAUNCHD_LABEL", cfg["BUNDLE_ID"] + ".mcp")
    cfg.setdefault("SUPPORT_DIR", "cursor-desktop")
    if not cfg.get("SUPPORT_DIR"):
        cfg["SUPPORT_DIR"] = "cursor-desktop"
    return cfg


_ID = _load_identity()
APP_DISPLAY_NAME = _ID["APP_DISPLAY_NAME"]
APP = os.path.join(ROOT, _ID["APP_BUNDLE"])
HELPER = os.path.join(APP, "Contents", "MacOS", _ID["EXEC"])
if not os.path.isfile(HELPER):
    HELPER = os.path.join(ROOT, "bin", "helper")
MAX_EDGE = 1280
JPEG_QUALITY = 72

PROTOCOL_VERSION = "2025-11-25"

_tcc: dict[str, Any] = {}
_tcc_at = 0.0


SOCK = os.path.expanduser(
    f"~/Library/Application Support/{_ID['SUPPORT_DIR']}/helper.sock"
)


def _helper_alive() -> bool:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.8)
        s.connect(SOCK)
        s.sendall(b'{"argv":["ping"]}\n')
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
        s.close()
        return b'"ok":true' in buf.replace(b" ", b"") or b'"ok": true' in buf
    except OSError:
        return False


def _ensure_daemon() -> None:
    if _helper_alive():
        return
    if not os.path.isdir(APP):
        raise RuntimeError(f"app missing: {APP} (run ./build.sh)")
    try:
        os.remove(SOCK)
    except OSError:
        pass
    os.makedirs(os.path.dirname(SOCK), exist_ok=True)
    subprocess.run(
        ["open", "-n", "-a", APP, "--args", "serve", "--socket", SOCK],
        check=True,
        timeout=8,
    )
    deadline = time.time() + 8
    while time.time() < deadline:
        if os.path.exists(SOCK) and _helper_alive():
            return
        time.sleep(0.08)
    raise RuntimeError(
        f"{APP_DISPLAY_NAME} did not start (unix socket). "
        "Quit leftover helper processes and try again."
    )


def _helper(args: list[str], timeout: float = 12.0) -> str:
    """Talk to the one resident helper. TCC attaches to our .app, not Cursor."""
    _ensure_daemon()
    argv = list(args)
    payload = (json.dumps({"argv": argv}) + "\n").encode("utf-8")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall(payload)
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    if not buf.strip():
        raise RuntimeError("helper socket closed with no reply")
    msg = json.loads(buf.decode("utf-8"))
    err = str(msg.get("stderr") or "").strip()
    data = str(msg.get("stdout") or "")
    if err and not data.strip():
        raise RuntimeError(err)
    if data.strip():
        return data
    if err:
        raise RuntimeError(err)
    if not msg.get("ok", True):
        raise RuntimeError(err or "helper failed")
    return data


def _windows() -> list[dict[str, Any]]:
    return json.loads(_helper(["list"]) or "[]")


def _match_window(app: str | None) -> dict[str, Any]:
    wins = _windows()
    if not wins:
        raise RuntimeError("No on-screen windows. Screen Recording may be denied for this process.")
    query = (app or "").strip().lower()
    if query:
        scored: list[tuple[int, dict[str, Any]]] = []
        for w in wins:
            owner = (w.get("owner") or "").lower()
            name = (w.get("name") or "").lower()
            blob = f"{owner} {name}"
            score = 0
            if query in owner:
                score += 30
            if query in name:
                score += 20
            if query in blob:
                score += 5
            if any(m in name for m in ("nouveau message", "new message")) and not any(
                m in query for m in ("nouveau", "new message")
            ):
                score -= 18
            area = int(w.get("w") or 0) * int(w.get("h") or 0)
            if score:
                scored.append((score * 10_000_000 + area, w))
        if not scored:
            owners = sorted({w.get("owner") or "?" for w in wins})
            raise RuntimeError(f"No window matching {query!r}. Visible owners: {', '.join(owners)}")
        scored.sort(key=lambda t: t[0], reverse=True)
        return scored[0][1]
    others = [w for w in wins if (w.get("owner") or "").lower() != "cursor"]
    pool = others or wins
    return max(pool, key=lambda w: int(w.get("w") or 0) * int(w.get("h") or 0))


def _ax_win_args(win: dict[str, Any]) -> list[str]:
    cmd: list[str] = []
    title = (win.get("name") or "").strip()
    if title:
        cmd += ["--title", title]
    cmd += [
        "--wid",
        str(int(win.get("id") or 0)),
        "--wx",
        str(float(win.get("x") or 0)),
        "--wy",
        str(float(win.get("y") or 0)),
        "--ww",
        str(float(win.get("w") or 0)),
        "--wh",
        str(float(win.get("h") or 0)),
    ]
    return cmd


def _capture_jpeg_fallback(window: dict[str, Any], dest_jpg: str) -> tuple[int, int]:
    """Cursor-parent screencapture. Used only while the .app's own Screen Recording preflight is false."""
    png = dest_jpg + ".png"
    wid = int(window.get("id") or 0)
    if wid:
        cmd = ["/usr/sbin/screencapture", "-l", str(wid), "-x", "-o", "-t", "png", png]
    else:
        cmd = [
            "/usr/sbin/screencapture",
            "-R",
            f"{int(window['x'])},{int(window['y'])},{int(window['w'])},{int(window['h'])}",
            "-x",
            "-o",
            "-t",
            "png",
            png,
        ]
    proc = subprocess.run(cmd, capture_output=True, timeout=8)
    if proc.returncode != 0 or not os.path.isfile(png) or os.path.getsize(png) < 32:
        raise RuntimeError(
            "Screenshot failed for both the helper app and Cursor-parent screencapture. "
            f"Toggle Screen Recording off/on for {APP_DISPLAY_NAME}, then quit its helper once."
        )
    subprocess.run(
        ["sips", "-Z", str(MAX_EDGE), png],
        check=True,
        capture_output=True,
        timeout=8,
    )
    subprocess.run(
        ["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(JPEG_QUALITY), png, "--out", dest_jpg],
        check=True,
        capture_output=True,
        timeout=8,
    )
    w = h = 0
    info = subprocess.check_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", dest_jpg], text=True)
    for line in info.splitlines():
        if "pixelWidth" in line:
            w = int(line.split()[-1])
        if "pixelHeight" in line:
            h = int(line.split()[-1])
    return w, h


def _helper_screen_ok() -> bool:
    """True when this helper process can actually capture (SCK or CGPreflight). Never --prompt."""
    global _tcc, _tcc_at
    now = time.time()
    if _tcc and now - _tcc_at < 8:
        return bool(_tcc.get("sck_ok") or _tcc.get("screen_recording"))
    try:
        _tcc = json.loads(_helper(["doctor"]) or "{}")
        _tcc_at = now
    except Exception:
        return False
    return bool(_tcc.get("sck_ok") or _tcc.get("screen_recording"))


def _capture_jpeg(window: dict[str, Any]) -> tuple[bytes, int, int]:
    tmp = tempfile.mkdtemp(prefix="cursor-custom-computer-use-")
    try:
        out = os.path.join(tmp, "view.jpg")
        if _helper_screen_ok():
            args = [
                "screenshot",
                "--out",
                out,
                "--max-edge",
                str(MAX_EDGE),
                "--quality",
                str(JPEG_QUALITY),
            ]
            wid = int(window.get("id") or 0)
            if wid:
                args += ["--id", str(wid)]
            else:
                args += [
                    "--x",
                    str(window["x"]),
                    "--y",
                    str(window["y"]),
                    "--w",
                    str(window["w"]),
                    "--h",
                    str(window["h"]),
                ]
            try:
                meta = json.loads(_helper(args) or "{}")
                data = open(out, "rb").read()
                if len(data) >= 32:
                    return data, int(meta.get("w") or 0), int(meta.get("h") or 0)
            except Exception:
                pass
        w, h = _capture_jpeg_fallback(window, out)
        data = open(out, "rb").read()
        if len(data) < 32:
            raise RuntimeError(
                "Screenshot empty. Cursor-parent screencapture failed; helper Screen Recording is still false."
            )
        return data, w, h
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _window_by_id(wid: int) -> dict[str, Any]:
    for w in _windows():
        if int(w.get("id") or 0) == int(wid):
            return w
    raise RuntimeError(f"window_id {wid} is not an open window; call get_app_state again.")


def _target_window(args: dict[str, Any]) -> dict[str, Any]:
    """The window a tool acts on, resolved only from the call's own arguments.

    `window_id` (from get_app_state) is preferred; `app` is a stateless fallback
    that matches against the live window list. Nothing is remembered between
    calls, so concurrent agents cannot clobber each other's target.
    """
    wid = args.get("window_id")
    if wid is not None:
        return _window_by_id(int(wid))
    app = args.get("app")
    if not (app or "").strip():
        raise RuntimeError(
            "pass window_id from get_app_state (or app=) so the target window is explicit; "
            "the server keeps no state between calls."
        )
    return _match_window(app)


def _anchor(args: dict[str, Any]) -> tuple[dict[str, Any], float, float]:
    """Window plus screenshot pixel size, both echoed back by the caller.

    x,y are screenshot pixels, so they only mean anything next to the capture
    they came from: the window and the image size get_app_state reported.
    """
    win = _target_window(args)
    px = args.get("image_px")
    if not (isinstance(px, (list, tuple)) and len(px) == 2):
        raise RuntimeError(
            "x,y are screenshot pixels: pass window_id and image_px [w,h] from get_app_state "
            "with the call, instead of relying on server state."
        )
    return win, float(px[0]), float(px[1])


def _map_click(
    x: float, y: float, win: dict[str, Any], image_w: float, image_h: float
) -> tuple[float, float]:
    sx = float(win["x"]) + (float(x) / image_w) * float(win["w"])
    sy = float(win["y"]) + (float(y) / image_h) * float(win["h"])
    return sx, sy


def _b64(data: bytes) -> str:
    import base64

    return base64.standard_b64encode(data).decode("ascii")


def tool_list_apps(_args: dict[str, Any]) -> dict[str, Any]:
    wins = _windows()
    slim = [
        {
            "id": w["id"],
            "pid": w["pid"],
            "owner": w["owner"],
            "name": w["name"],
            "bounds": [int(w["x"]), int(w["y"]), int(w["w"]), int(w["h"])],
            "on_screen": w.get("on_screen"),
        }
        for w in wins
    ]
    return _text(json.dumps(slim, ensure_ascii=False))


def tool_isolate_window(args: dict[str, Any]) -> dict[str, Any]:
    win = _target_window(args)
    mode = str(args.get("mode") or "raise").lower()
    if mode not in ("raise", "fullscreen"):
        mode = "raise"
    cmd = ["isolate", "--pid", str(int(win["pid"])), "--mode", mode] + _ax_win_args(win)
    out = _helper(cmd, timeout=15)
    return _text(out.strip() or json.dumps({"ok": True, "mode": mode}))


def tool_get_app_state(args: dict[str, Any]) -> dict[str, Any]:
    win = _match_window(args.get("app"))
    jpeg, iw, ih = _capture_jpeg(win)
    ax_text = ""
    ax_count = 0
    ax_err = ""
    ax_picked = ""
    ax_windows: list[Any] = []
    ax_focused = ""
    ax_role = ""
    ax_window_ids: list[Any] = []
    synthetic_key = ""
    try:
        dump_args = ["ax-dump", "--pid", str(int(win["pid"])), "--max", "600"] + _ax_win_args(win)
        ax = json.loads(_helper(dump_args, timeout=35) or "{}")
        ax_text = str(ax.get("text") or "")
        ax_count = int(ax.get("count") or 0)
        ax_picked = str(ax.get("picked_title") or "")
        ax_windows = list(ax.get("window_titles") or [])
        ax_focused = str(ax.get("focused_title") or "")
        ax_role = str(ax.get("picked_role") or "")
        ax_window_ids = list(ax.get("window_ids") or [])
        synthetic_key = str(ax.get("synthetic_key") or "")
        if not (win.get("name") or "").strip() and ax_text:
            import re

            m = re.search(r'title="([^"]+)"', ax_text)
            if m:
                win["name"] = m.group(1)
    except Exception as exc:
        ax_err = str(exc)
    meta = {
        "app": win["owner"],
        "window": win["name"],
        "pid": win["pid"],
        "window_id": win["id"],
        "bounds_points": [int(win["x"]), int(win["y"]), int(win["w"]), int(win["h"])],
        "image_px": [iw, ih],
        "ax_count": ax_count,
        "ax_window": ax_picked,
        "ax_windows": ax_windows,
        "ax_focused": ax_focused,
        "ax_role": ax_role,
        "ax_window_ids": ax_window_ids,
        "synthetic_key": synthetic_key,
        "on_screen": win.get("on_screen"),
        "click_space": (
            "prefer element_index from the AX tree; else screenshot pixels, origin top-left. "
            "Pass window_id and image_px back with click/drag — the server keeps no state."
        ),
    }
    if ax_err:
        meta["ax_error"] = ax_err
    text_parts = [json.dumps(meta, ensure_ascii=False)]
    if ax_text:
        text_parts.append(ax_text)
    elif ax_err:
        text_parts.append(f"(no AX tree: {ax_err})")
    else:
        text_parts.append("(empty AX tree — use the screenshot; common for GPU views like Unreal)")
    return {
        "content": [
            {"type": "text", "text": "\n".join(text_parts)},
            {"type": "image", "mimeType": "image/jpeg", "data": _b64(jpeg)},
        ]
    }


def tool_click(args: dict[str, Any]) -> dict[str, Any]:
    if args.get("global") and args.get("element_index") is not None:
        raise RuntimeError(
            "global click needs x,y: it moves the real pointer, so there is no element_index path"
        )
    if args.get("element_index") is not None:
        win = _target_window(args)
        cmd = [
            "click",
            "--index",
            str(int(args["element_index"])),
            "--pid",
            str(int(win["pid"])),
        ] + _ax_win_args(win)
        if args.get("mouse_button"):
            cmd += ["--button", str(args["mouse_button"])]
        out = _helper(cmd, timeout=15)
        return _text(out.strip() or '{"ok":true}')
    if args.get("x") is None or args.get("y") is None:
        raise RuntimeError("click needs element_index (preferred) or x,y screenshot pixels")
    win, iw, ih = _anchor(args)
    sx, sy = _map_click(args["x"], args["y"], win, iw, ih)
    button = str(args.get("mouse_button") or args.get("button") or "left")
    count = int(args.get("click_count") or args.get("count") or 1)
    cmd = [
        "click",
        "--x",
        str(sx),
        "--y",
        str(sy),
        "--button",
        button,
        "--count",
        str(count),
        "--pid",
        str(int(win["pid"])),
    ]
    if args.get("global"):
        cmd += ["--global"]
    cmd += _ax_win_args(win)
    out = _helper(cmd, timeout=15)
    result = json.loads(out.strip() or "{}")
    result.setdefault("screen", [round(sx, 1), round(sy, 1)])
    return _text(json.dumps(result))


def tool_drag(args: dict[str, Any]) -> dict[str, Any]:
    win, iw, ih = _anchor(args)
    x1, y1 = _map_click(args["from_x"], args["from_y"], win, iw, ih)
    x2, y2 = _map_click(args["to_x"], args["to_y"], win, iw, ih)
    cmd = [
        "drag",
        "--from-x",
        str(x1),
        "--from-y",
        str(y1),
        "--to-x",
        str(x2),
        "--to-y",
        str(y2),
        "--pid",
        str(int(win["pid"])),
    ]
    if args.get("global"):
        cmd += ["--global"]
    cmd += _ax_win_args(win)
    out = _helper(cmd, timeout=15)
    return _text(out.strip() or '{"ok":true}')


def tool_scroll(args: dict[str, Any]) -> dict[str, Any]:
    if args.get("element_index") is None:
        raise RuntimeError(
            "scroll needs element_index from the last AX tree (the list, web area, or a row inside it)."
        )
    win = _target_window(args)
    direction = str(args.get("direction") or "down").lower()
    pages = float(args.get("pages") or 1)
    if pages <= 0:
        raise RuntimeError("pages must be > 0")
    cmd = [
        "scroll",
        "--index",
        str(int(args["element_index"])),
        "--direction",
        direction,
        "--pages",
        str(pages),
        "--pid",
        str(int(win["pid"])),
    ] + _ax_win_args(win)
    return _text(_helper(cmd, timeout=25).strip() or '{"ok":true}')


def tool_type_text(args: dict[str, Any]) -> dict[str, Any]:
    win = _target_window(args)
    cmd = ["type", "--text", str(args.get("text") or ""), "--pid", str(int(win["pid"]))] + _ax_win_args(
        win
    )
    if args.get("element_index") is not None:
        cmd += ["--index", str(int(args["element_index"]))]
    return _text(_helper(cmd, timeout=20).strip() or '{"ok":true}')


def tool_press_key(args: dict[str, Any]) -> dict[str, Any]:
    win = _target_window(args)
    spec = str(args.get("key") or "")
    _helper(["key", "--spec", spec, "--pid", str(int(win["pid"]))] + _ax_win_args(win))
    return _text('{"ok":true}')


def tool_set_value(args: dict[str, Any]) -> dict[str, Any]:
    win = _target_window(args)
    cmd = [
        "set-value",
        "--index",
        str(int(args["element_index"])),
        "--text",
        str(args.get("value") or ""),
        "--pid",
        str(int(win["pid"])),
    ] + _ax_win_args(win)
    return _text(_helper(cmd, timeout=15).strip() or '{"ok":true}')


def tool_perform_secondary_action(args: dict[str, Any]) -> dict[str, Any]:
    win = _target_window(args)
    cmd = [
        "ax-action",
        "--index",
        str(int(args["element_index"])),
        "--action",
        str(args.get("action") or ""),
        "--pid",
        str(int(win["pid"])),
    ] + _ax_win_args(win)
    return _text(_helper(cmd, timeout=15).strip() or '{"ok":true}')


def _text(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}]}


def _err(text: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": text}], "isError": True}


TOOLS = {
    "list_apps": {
        "description": (
            "List windows including other Spaces. on_screen=false means HID click would hit this Space; "
            "AX element_index / AX scroll / pid keys still work. Does not activate anything."
        ),
        "schema": {"type": "object", "properties": {}},
        "fn": tool_list_apps,
    },
    "get_app_state": {
        "description": (
            "AX tree plus JPEG of one window. Does not bring the app forward or switch Spaces. "
            "Prefer element_index from the tree; screenshot when AX is empty (GPU views)."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "app": {
                    "type": "string",
                    "description": "Window owner or title substring, e.g. Mail or UnrealEditor.",
                }
            },
        },
        "fn": tool_get_app_state,
    },
    "isolate_window": {
        "description": (
            "Raise the window given by window_id (or app=) and optionally fullscreen it. "
            "This comes to the front and may switch Spaces. Leaves it front."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "window_id": {"type": "integer"},
                "app": {"type": "string"},
                "mode": {"type": "string", "enum": ["raise", "fullscreen"]},
            },
        },
        "fn": tool_isolate_window,
    },
    "click": {
        "description": (
            "Click an AX element_index, or screenshot x,y posted to that window's pid "
            "(off-Space; does not move your pointer). x,y come from get_app_state, so pass that "
            "call's window_id and image_px back with them — the server keeps no state. Set "
            "global=true to force the real-pointer path instead: the window is raised first and "
            "the mouse actually moves. Use it only as a fallback when a pid click had no effect "
            "(some native apps ignore pid-posted clicks), or when the user explicitly wants "
            "control taken over. The result reports via=pid|hid|global."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "element_index": {"type": "integer"},
                "x": {"type": "number"},
                "y": {"type": "number"},
                "window_id": {"type": "integer"},
                "image_px": {"type": "array", "items": {"type": "integer"}},
                "app": {"type": "string"},
                "mouse_button": {"type": "string", "enum": ["left", "right", "middle"]},
                "click_count": {"type": "integer"},
                "global": {"type": "boolean"},
            },
        },
        "fn": tool_click,
    },
    "drag": {
        "description": (
            "Drag in get_app_state's screenshot pixels, posted to the window's pid (no real "
            "pointer). Pass window_id and image_px from that call; the server keeps no state. "
            "Set global=true to force the real-pointer path: the window is raised first and the "
            "mouse actually moves. The pid path cannot drive window-server drags (window moves, "
            "text selection, Finder drag-and-drop), so use global for those. Reports via=pid|global."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "from_x": {"type": "number"},
                "from_y": {"type": "number"},
                "to_x": {"type": "number"},
                "to_y": {"type": "number"},
                "window_id": {"type": "integer"},
                "image_px": {"type": "array", "items": {"type": "integer"}},
                "global": {"type": "boolean"},
            },
            "required": ["from_x", "from_y", "to_x", "to_y"],
        },
        "fn": tool_drag,
    },
    "scroll": {
        "description": (
            "Scroll an element from the AX tree by pages (up/down/left/right). "
            "Requires element_index (the list, web area, or a row inside it). "
            "Uses AX page-scroll or that container's scrollbar; pid-wheel only if those actually move. "
            "Does not guess a point in the window. WebKit often needs AXScrollToVisible on a descendant instead."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "element_index": {"type": "integer"},
                "direction": {"type": "string"},
                "pages": {"type": "number"},
                "window_id": {"type": "integer"},
                "app": {"type": "string"},
            },
            "required": ["element_index"],
        },
        "fn": tool_scroll,
    },
    "type_text": {
        "description": (
            "Type into the target window like Codex type_text: unicode key events to that pid "
            "(into current focus, or element_index first). Not a global shortcut."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "window_id": {"type": "integer"},
                "app": {"type": "string"},
                "element_index": {"type": "integer"},
            },
            "required": ["text"],
        },
        "fn": tool_type_text,
    },
    "press_key": {
        "description": (
            "Key or combo into the target window only (pid-directed, not global). "
            "Examples: Return, Tab, Escape, cmd+s, Up."
        ),
        "schema": {
            "type": "object",
            "properties": {
                "key": {"type": "string"},
                "window_id": {"type": "integer"},
                "app": {"type": "string"},
            },
            "required": ["key"],
        },
        "fn": tool_press_key,
    },
    "set_value": {
        "description": "Set AX value on element_index. Does not activate the app.",
        "schema": {
            "type": "object",
            "properties": {
                "element_index": {"type": "integer"},
                "value": {"type": "string"},
                "window_id": {"type": "integer"},
                "app": {"type": "string"},
            },
            "required": ["element_index", "value"],
        },
        "fn": tool_set_value,
    },
    "perform_secondary_action": {
        "description": "AX action named in the tree (Show Menu, Expand, …).",
        "schema": {
            "type": "object",
            "properties": {
                "element_index": {"type": "integer"},
                "action": {"type": "string"},
                "window_id": {"type": "integer"},
                "app": {"type": "string"},
            },
            "required": ["element_index", "action"],
        },
        "fn": tool_perform_secondary_action,
    },
}


def _tools_list() -> dict[str, Any]:
    return {
        "tools": [
            {
                "name": name,
                "description": spec["description"],
                "inputSchema": spec["schema"],
            }
            for name, spec in TOOLS.items()
        ]
    }


def _call(name: str, arguments: dict[str, Any] | None) -> dict[str, Any]:
    spec = TOOLS.get(name)
    if not spec:
        return _err(f"Unknown tool {name}")
    try:
        return spec["fn"](arguments or {})
    except Exception as exc:
        return _err(str(exc))


def _handle(msg: dict[str, Any]) -> dict[str, Any] | None:
    method = msg.get("method")
    msg_id = msg.get("id")
    if method == "initialize":
        requested = ((msg.get("params") or {}).get("protocolVersion") or PROTOCOL_VERSION)
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": requested,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "computer-use", "version": "1.0.0"},
            },
        }
    if method == "notifications/initialized" or method == "notifications/cancelled":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": msg_id, "result": _tools_list()}
    if method == "tools/call":
        params = msg.get("params") or {}
        result = _call(str(params.get("name") or ""), params.get("arguments") or {})
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}
    if msg_id is None:
        return None
    return {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {"code": -32601, "message": f"Unknown method {method}"},
    }


def _read_message(stdin) -> dict[str, Any] | None:
    header = b""
    while True:
        line = stdin.readline()
        if not line:
            return None
        if line in (b"\n", b"\r\n"):
            break
        header += line
    if not header:
        rest = stdin.readline()
        if not rest:
            return None
        return json.loads(rest.decode("utf-8"))
    length = None
    for raw in header.splitlines():
        line = raw.decode("utf-8", errors="replace")
        if line.lower().startswith("content-length:"):
            length = int(line.split(":", 1)[1].strip())
    if length is None:
        try:
            return json.loads(header.decode("utf-8"))
        except json.JSONDecodeError:
            return None
    body = stdin.read(length)
    if not body:
        return None
    return json.loads(body.decode("utf-8"))


def _write_message(payload: dict[str, Any]) -> None:
    raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()


def main() -> int:
    try:
        with open("/tmp/cua-mcp-debug.log", "a", encoding="utf-8") as dbg:
            dbg.write(f"start pid={os.getpid()} py={sys.executable}\n")
    except Exception:
        pass
    stdin = sys.stdin.buffer
    while True:
        try:
            message = _read_message(stdin)
        except json.JSONDecodeError as exc:
            _write_message(
                {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": str(exc)}}
            )
            continue
        if message is None:
            try:
                with open("/tmp/cua-mcp-debug.log", "a", encoding="utf-8") as dbg:
                    dbg.write("eof\n")
            except Exception:
                pass
            return 0
        try:
            with open("/tmp/cua-mcp-debug.log", "a", encoding="utf-8") as dbg:
                dbg.write(f"msg {message.get('method')} id={message.get('id')}\n")
        except Exception:
            pass
        reply = _handle(message)
        if reply is not None:
            _write_message(reply)
    return 0


def rpc_main() -> int:
    """NDJSON tool worker. Stdio MCP is mcp.mjs — Apple python3 becomes Python.app and drops Cursor's pipe."""
    try:
        with open("/tmp/cua-mcp-debug.log", "a", encoding="utf-8") as dbg:
            dbg.write(f"rpc pid={os.getpid()} py={sys.executable}\n")
    except Exception:
        pass
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = None
        try:
            msg = json.loads(line)
            result = _call(str(msg.get("name") or ""), msg.get("arguments") or {})
            sys.stdout.write(json.dumps({"id": msg.get("id"), "result": result}, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        except Exception as exc:
            sys.stdout.write(
                json.dumps(
                    {"id": (msg.get("id") if isinstance(msg, dict) else None), "result": _err(str(exc))},
                    ensure_ascii=False,
                )
                + "\n"
            )
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    if "--tools" in sys.argv:
        sys.stdout.write(json.dumps(_tools_list(), ensure_ascii=False) + "\n")
        raise SystemExit(0)
    if "--rpc" in sys.argv:
        raise SystemExit(rpc_main())
    raise SystemExit(main())
