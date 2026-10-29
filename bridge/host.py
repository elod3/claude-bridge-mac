#!/usr/bin/env python3
"""Claude Bridge: the native-messaging host.

Firefox starts this for the Claude Bridge extension (through the manifest
claude_bridge.json that install.sh writes) and it lives as long as the
browser does. It opens a unix socket only this user can reach and relays:
a line of JSON {"method", "params"} from mcp.py goes to the extension, the
extension's answer comes back as a line of JSON.
"""
import json
import os
import socket
import struct
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paths import sock_path  # noqa: E402

out_lock = threading.Lock()
pending = {}          # request id -> (event, [reply])
pending_lock = threading.Lock()
counter = [0]


def to_browser(msg):
    data = json.dumps(msg).encode()
    with out_lock:
        sys.stdout.buffer.write(struct.pack("<I", len(data)) + data)
        sys.stdout.buffer.flush()


def read_exact(n):
    buf = b""
    while len(buf) < n:
        chunk = sys.stdin.buffer.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def from_browser():
    while True:
        head = read_exact(4)
        if head is None:
            os._exit(0)            # the browser closed: go with it
        (n,) = struct.unpack("<I", head)
        body = read_exact(n)
        if body is None:
            os._exit(0)
        msg = json.loads(body)
        with pending_lock:
            waiter = pending.pop(msg.get("id"), None)
        if waiter:
            waiter[1].append(msg)
            waiter[0].set()


def serve(conn):
    with conn, conn.makefile("rwb") as f:
        for raw in f:
            try:
                req = json.loads(raw)
            except ValueError:
                continue
            with pending_lock:
                counter[0] += 1
                rid = counter[0]
                done = threading.Event()
                pending[rid] = (done, [])
                box = pending[rid][1]
            to_browser({"id": rid, "method": req.get("method"), "params": req.get("params") or {}})
            if not done.wait(req.get("timeout", 60)):
                with pending_lock:
                    pending.pop(rid, None)
                reply = {"error": "the browser did not answer in time"}
            else:
                reply = box[0]
            reply.pop("id", None)
            f.write((json.dumps(reply) + "\n").encode())
            f.flush()


def peer_uid(conn):
    """The uid at the other end of the socket, or None if this system
    gives no way to ask (the folder's 0700 mode still keeps others out)."""
    try:
        if hasattr(socket, "SO_PEERCRED"):                      # Linux
            return struct.unpack("3i", conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
        if sys.platform == "darwin":
            # LOCAL_PEERCRED (SOL_LOCAL 0, option 1) gives a struct xucred:
            # u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16]
            raw = conn.getsockopt(0, 1, 76)
            version, uid = struct.unpack_from("=II", raw)
            # XUCRED_VERSION is 0; anything else is a layout this code does
            # not know, so it does not judge by it
            return uid if version == 0 else None
    except OSError:
        return None
    return None


def main():
    path = sock_path(create=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    old = os.umask(0o177)          # socket is 0600
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.umask(old)
    srv.listen(4)
    threading.Thread(target=from_browser, daemon=True).start()
    me = os.getuid()
    while True:
        conn, _ = srv.accept()
        uid = peer_uid(conn)
        if uid is not None and uid != me:
            conn.close()
            continue
        threading.Thread(target=serve, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
