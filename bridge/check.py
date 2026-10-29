#!/usr/bin/env python3
"""Is the bridge up? Waits up to N seconds (default 0) for the browser,
then asks it for its tabs the same way mcp.py does. Exit 0 and a line
saying how many tabs, or exit 1 and why not."""
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paths import sock_path  # noqa: E402


def ask():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(30)
    s.connect(sock_path())
    with s, s.makefile("rwb") as f:
        f.write((json.dumps({"method": "tabs", "params": {}, "timeout": 20}) + "\n").encode())
        f.flush()
        reply = json.loads(f.readline())
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply["result"]


def main():
    wait = float(sys.argv[1]) if len(sys.argv) > 1 else 0
    end = time.time() + wait
    while True:
        try:
            tabs = ask()
            print(f"ok: the bridge answers, {len(tabs)} tab(s) open")
            return 0
        except (OSError, ValueError, RuntimeError) as e:
            if time.time() >= end:
                print(f"no answer: {e}")
                return 1
            time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
