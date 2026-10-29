"""Where Claude Bridge keeps its socket, shared by host.py and mcp.py.

The socket sits in a folder only this user can open (0700), inside the
bridge's own home: ~/Library/Application Support/ClaudeBridge on a Mac,
~/.local/share/claude-bridge elsewhere, or $CLAUDE_BRIDGE_HOME. A unix
socket path has a length limit (104 bytes on macOS), so a very long home
falls back to a private folder under /tmp.
"""
import os
import sys

LIMIT = 100


def home():
    if os.environ.get("CLAUDE_BRIDGE_HOME"):
        return os.environ["CLAUDE_BRIDGE_HOME"]
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/ClaudeBridge")
    return os.path.expanduser("~/.local/share/claude-bridge")


def _private_dir(d, create):
    if create:
        os.makedirs(d, mode=0o700, exist_ok=True)
        if os.stat(d).st_uid != os.getuid():
            raise RuntimeError(d + " belongs to someone else")
        os.chmod(d, 0o700)
    return d


def sock_path(create=False):
    p = os.path.join(home(), "run", "bridge.sock")
    if len(p.encode()) <= LIMIT:
        _private_dir(os.path.dirname(p), create)
        return p
    d = _private_dir(f"/tmp/claude-bridge-{os.getuid()}", create)
    return os.path.join(d, "bridge.sock")
