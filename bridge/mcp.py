#!/usr/bin/env python3
"""Claude Bridge: the MCP server Claude Code talks to (stdio).

Registered once by install.sh. Each tool call goes over the unix socket
host.py keeps open while Claude Browser runs, to the Claude Bridge
extension inside it. Tabs are the browser's real tabs, with the user's
sign-ins.
"""
import json
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paths import sock_path  # noqa: E402

TAB = {"type": "integer", "description": "tab id from tabs_list; the active tab if left out"}
REF = {"type": "string", "description": "element ref from read_page or find, e.g. ref_12"}

TOOLS = [
    ("tabs_list", "List the browser's open tabs: id, window, title, URL, which one is active.", {}, [], "tabs"),
    ("tab_open", "Open a new tab at a URL (none: an empty tab) and wait for it to load.",
     {"url": {"type": "string"}, "active": {"type": "boolean", "description": "bring it to the front (default true)"}}, [], "open"),
    ("navigate", "Load a URL in a tab, or go 'back' / 'forward' / 'reload'. Waits for the load.",
     {"tab": TAB, "url": {"type": "string"}}, ["url"], "navigate"),
    ("tab_activate", "Bring a tab to the front.", {"tab": TAB}, [], "activate"),
    ("tab_close", "Close a tab.", {"tab": TAB}, ["tab"], "close"),
    ("screenshot", "Screenshot of a tab's visible area (it is brought to the front). Pixel coordinates on it are the x/y that click takes.",
     {"tab": TAB}, [], "screenshot"),
    ("read_page", "The page's elements you can act on, one per line: ref, kind, name, centre x,y, value. filter='all' adds headings and text blocks.",
     {"tab": TAB, "filter": {"type": "string", "enum": ["interactive", "all"]}, "limit": {"type": "integer"}}, [], "read"),
    ("get_page_text", "The page's visible text (title and URL first).", {"tab": TAB, "limit": {"type": "integer"}}, [], "text"),
    ("find", "Find elements whose text or label contains a string; gives their refs.", {"tab": TAB, "query": {"type": "string"}}, ["query"], "find"),
    ("click", "Click an element by ref, or at x,y (CSS pixels, as on the screenshot).",
     {"tab": TAB, "ref": REF, "x": {"type": "number"}, "y": {"type": "number"},
      "button": {"type": "string", "enum": ["left", "right", "middle"]}, "double": {"type": "boolean"}}, [], "click"),
    ("type", "Type text into an element (by ref, or the focused one). clear=true replaces what is there.",
     {"tab": TAB, "ref": REF, "text": {"type": "string"}, "clear": {"type": "boolean"}}, ["text"], "type"),
    ("key", "Press a key or chord on the focused element or a ref: Enter, Tab, Escape, ArrowDown, ctrl+a …",
     {"tab": TAB, "key": {"type": "string"}, "ref": REF}, ["key"], "key"),
    ("scroll", "Scroll the page (dy pixels, default most of a screen), or an element by ref (no dx/dy: scroll it into view).",
     {"tab": TAB, "ref": REF, "dx": {"type": "number"}, "dy": {"type": "number"}}, [], "scroll"),
    ("select_option", "Choose an option of a <select> by value or visible text.", {"tab": TAB, "ref": REF, "value": {"type": "string"}}, ["ref", "value"], "select"),
    ("javascript", "Run JavaScript on the page and get the result as JSON: an expression, or statements with `return`; await works. It sees the DOM; the page's own globals are on window.wrappedJSObject. Page CSP does not block it.",
     {"tab": TAB, "code": {"type": "string"}}, ["code"], "js"),
]
BY_NAME = {t[0]: t for t in TOOLS}


def call_browser(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(sock_path())
    except OSError:
        raise RuntimeError("Claude Browser is not running, or its Claude Bridge extension is off. "
                           "Open the Claude Browser app (in ~/Applications) and try again.")
    with s, s.makefile("rwb") as f:
        f.write((json.dumps({"method": method, "params": params, "timeout": 60}) + "\n").encode())
        f.flush()
        line = f.readline()
    if not line:
        raise RuntimeError("Claude Browser closed the connection")
    reply = json.loads(line)
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply.get("result")


def run_tool(name, args):
    method = BY_NAME[name][4]
    params = {k: v for k, v in (args or {}).items() if v is not None}
    result = call_browser(method, params)
    if name == "screenshot":
        meta = {k: result[k] for k in ("width", "height", "scrollX", "scrollY")}
        return [{"type": "image", "data": result["png"], "mimeType": "image/png"},
                {"type": "text", "text": f"viewport {meta['width']}x{meta['height']} CSS px, scrolled to {meta['scrollX']},{meta['scrollY']}"}]
    if name == "javascript" and isinstance(result, str):
        return [{"type": "text", "text": result}]
    text = result if isinstance(result, str) else json.dumps(result, indent=1, ensure_ascii=False)
    return [{"type": "text", "text": text}]


def reply(mid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": mid}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for raw in sys.stdin:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        method, mid = msg.get("method"), msg.get("id")
        if mid is None:
            continue                                   # notifications
        if method == "initialize":
            reply(mid, {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "bridge", "version": "1.0.0"},
                        "instructions": "Drives the user's Claude Browser (Firefox Developer Edition with Előd's Claude Bridge) "
                                        "with their real sign-ins. Start with tabs_list or tab_open; read_page gives refs to click/type."})
        elif method == "tools/list":
            reply(mid, {"tools": [{"name": n, "description": d,
                                   "inputSchema": {"type": "object", "properties": p, "required": r}}
                                  for n, d, p, r, _ in TOOLS]})
        elif method == "tools/call":
            p = msg.get("params", {})
            if p.get("name") not in BY_NAME:
                reply(mid, error={"code": -32602, "message": "unknown tool " + str(p.get("name"))})
                continue
            try:
                reply(mid, {"content": run_tool(p["name"], p.get("arguments"))})
            except Exception as e:
                reply(mid, {"content": [{"type": "text", "text": str(e)}], "isError": True})
        elif method == "ping":
            reply(mid, {})
        else:
            reply(mid, error={"code": -32601, "message": "no method " + str(method)})


if __name__ == "__main__":
    main()
