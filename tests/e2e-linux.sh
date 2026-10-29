#!/bin/bash
# End-to-end test of install.sh and the bridge, on Linux, as close to a Mac
# as Linux gets:
#   - a fake $HOME whose paths have spaces ("Application Support"), like macOS;
#   - stubs for the macOS-only commands (uname says Darwin, open runs the
#     app bundle's launcher, xattr does nothing, claude records its call);
#   - "Firefox Developer Edition.app" in ~/Applications is a wrapper around
#     the Linux Firefox Developer Edition, on a headless X server;
#   - the bridge runs on Python 3.9, the oldest macOS ships (Xcode CLT).
# Then it drives the browser through mcp.py: every tool, on a local page.
#
#   tests/e2e-linux.sh /path/to/linux/firefox [/path/to/python3.9]
set -u
FFBIN=${1:?firefox path}
PY39=${2:-$(uv python find 3.9)}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d /tmp/cb-e2e.XXXX)
FAKE="$T/home"
STUB="$T/stub"
fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }

mkdir -p "$FAKE/Applications/Firefox Developer Edition.app/Contents/MacOS" "$FAKE/Applications/Firefox Developer Edition.app/Contents/Resources" "$STUB" "$T/site"
printf '#!/bin/sh\nexec %q "$@"\n' "$FFBIN" > "$FAKE/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox"
chmod +x "$FAKE/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox"
echo icns > "$FAKE/Applications/Firefox Developer Edition.app/Contents/Resources/firefox.icns"

cat > "$STUB/uname" <<'EOF'
#!/bin/sh
echo Darwin
EOF
cat > "$STUB/xattr" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUB/open" <<'EOF'
#!/bin/sh
# open X.app: run its launcher in the background, like LaunchServices
exe=$(sed -n 's:.*<key>CFBundleExecutable</key><string>\(.*\)</string>.*:\1:p' "$1/Contents/Info.plist")
nohup "$1/Contents/MacOS/$exe" >"$OPEN_LOG" 2>&1 &
EOF
cat > "$STUB/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CLAUDE_LOG"
EOF
# only Python 3.9 is "installed"
ln -s "$PY39" "$STUB/python3"
chmod +x "$STUB"/*

# Firefox on Linux reads native-messaging manifests from ~/.mozilla; on a Mac
# it is ~/Library/Application Support/Mozilla. Point one at the other.
mkdir -p "$FAKE/Library/Application Support/Mozilla/NativeMessagingHosts" "$FAKE/.mozilla"
ln -s "$FAKE/Library/Application Support/Mozilla/NativeMessagingHosts" "$FAKE/.mozilla/native-messaging-hosts"

export HOME="$FAKE" PATH="$STUB:$PATH" CLAUDE_LOG="$T/claude.log" OPEN_LOG="$T/firefox.log"
# sys.platform is linux here: give paths.py the Mac home explicitly
export CLAUDE_BRIDGE_HOME="$FAKE/Library/Application Support/ClaudeBridge"
export DISPLAY=:79 MOZ_ENABLE_WAYLAND=0
Xvfb :79 -screen 0 1440x900x24 >/dev/null 2>&1 &
XPID=$!
sleep 1

cleanup() {
    pkill -P $$ >/dev/null 2>&1
    for p in $(pgrep -u "$(id -u)" -f -- "-profile $FAKE" 2>/dev/null); do kill "$p" 2>/dev/null; done
    kill $XPID 2>/dev/null
}
trap cleanup EXIT

echo "== install.sh"
bash "$ROOT/install.sh" > "$T/install.log" 2>&1
rc=$?
cat "$T/install.log" | sed 's/^/   | /'
[ $rc = 0 ] && ok "install.sh exit 0" || bad "install.sh exit $rc"

BH="$CLAUDE_BRIDGE_HOME"
[ -x "$BH/bridge/host" ] && ok "host wrapper" || bad "host wrapper"
grep -q "python3" "$BH/bridge/host" && ok "host names its python" || bad "host python"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["allowed_extensions"]==["claude-bridge@elod"] and m["path"].endswith("/bridge/host")' \
  "$FAKE/Library/Application Support/Mozilla/NativeMessagingHosts/claude_bridge.json" && ok "native-messaging manifest" || bad "manifest"
grep -q "mcp add --scope user bridge -- $STUB/python3 $BH/bridge/mcp.py" "$CLAUDE_LOG" && ok "claude mcp add" || { bad "claude mcp add"; cat "$CLAUDE_LOG"; }
[ "$(cat "$BH/profile/extensions/claude-bridge@elod")" = "$BH/extension" ] && ok "proxy file" || bad "proxy file"
[ -f "$FAKE/Applications/Claude Browser.app/Contents/Resources/browser.icns" ] && ok "app icon" || bad "app icon"
stat -c %a "$BH" | grep -q 700 && ok "home is 0700" || bad "home mode"
stat -c %a "$BH/run" | grep -q 700 && ok "run dir is 0700" || bad "run dir mode"
stat -c %a "$BH/run/bridge.sock" | grep -q 600 && ok "socket is 0600" || bad "socket mode"
pgrep -f "$BH/bridge/host.py" | while read -r p; do
    exe=$(readlink "/proc/$p/exe"); case "$exe" in *python3.9*) echo "PASS  host runs on $exe";; *) echo "FAIL  host runs on $exe";; esac
done

echo "== install.sh again (update over an install)"
bash "$ROOT/install.sh" > "$T/install2.log" 2>&1 && ok "second install exit 0" || { bad "second install"; tail -5 "$T/install2.log"; }

echo "== the MCP server, every tool"
cat > "$T/site/index.html" <<'EOF'
<!doctype html><title>Bridge test</title>
<h1>Hello bridge</h1>
<form onsubmit="event.preventDefault();document.getElementById('out').textContent='sent:'+this.n.value+':'+this.c.value">
<input name="n" aria-label="Name"><select name="c" aria-label="Colour"><option>red</option><option>blue</option></select>
<button>Send</button></form><p id="out"></p>
<div style="height:3000px"></div><p id="far">far away</p>
EOF
( cd "$T/site" && exec "$PY39" -m http.server 8971 >/dev/null 2>&1 ) &
sleep 1
"$PY39" - "$ROOT/bridge/mcp.py" <<'EOF'
import json, subprocess, sys, base64
p = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
n = [0]
def rpc(method, params=None):
    n[0] += 1
    p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": n[0], "method": method, "params": params or {}}) + "\n"); p.stdin.flush()
    return json.loads(p.stdout.readline())
def tool(name, **a):
    r = rpc("tools/call", {"name": name, "arguments": a})["result"]
    if r.get("isError"): raise SystemExit("FAIL  %s: %s" % (name, r["content"][0]["text"]))
    return r["content"]
def text(name, **a): return tool(name, **a)[0]["text"]
def check(cond, what):
    print(("PASS  " if cond else "FAIL  ") + what)
    if not cond: check.failed = True
check.failed = False

init = rpc("initialize", {"protocolVersion": "2025-06-18"})["result"]
check(init["serverInfo"]["name"] == "bridge", "initialize")
names = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
check(len(names) == 15, "tools/list: %d tools" % len(names))
tabs = json.loads(text("tabs_list")); check(len(tabs) >= 1, "tabs_list")
t = json.loads(text("tab_open", url="http://127.0.0.1:8971/"))
tab = t["tab"]; check(t["title"] == "Bridge test", "tab_open + wait for load")
check("Hello bridge" in text("get_page_text", tab=tab), "get_page_text")
page = text("read_page", tab=tab)
ref_in = [l.split()[0] for l in page.splitlines() if "Name" in l][0]
ref_sel = [l.split()[0] for l in page.splitlines() if "Colour" in l][0]
check(ref_in.startswith("ref_"), "read_page gives refs")
text("type", tab=tab, ref=ref_in, text="Alin")
text("select_option", tab=tab, ref=ref_sel, value="blue")
btn_ref = text("find", tab=tab, query="Send").splitlines()[0].split()[0]
check(btn_ref.startswith("ref_"), "find")
text("click", tab=tab, ref=btn_ref)
check(json.loads(text("javascript", tab=tab, code="document.getElementById('out').textContent")) == "sent:Alin:blue", "type + select_option + find + click (form sent)")
check(json.loads(text("javascript", tab=tab, code="const a = 2; return a * 21")) == 42, "javascript with statements")
check(json.loads(text("javascript", tab=tab, code="navigator.webdriver")) is False, "navigator.webdriver is false")
text("scroll", tab=tab, dy=2500)
check(json.loads(text("javascript", tab=tab, code="scrollY")) > 1000, "scroll")
text("key", tab=tab, key="Escape")
check(True, "key")
shot = tool("screenshot", tab=tab)
png = base64.b64decode(shot[0]["data"]); check(png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) > 1000, "screenshot is a PNG (%d bytes)" % len(png))
nav = json.loads(text("navigate", tab=tab, url="http://127.0.0.1:8971/?second")); check(nav["url"].endswith("?second"), "navigate")
back = json.loads(text("navigate", tab=tab, url="back")); check(back["url"].endswith("/"), "navigate back")
text("tab_activate", tab=tab); check(True, "tab_activate")
text("tab_close", tab=tab)
check(all(x["tab"] != tab for x in json.loads(text("tabs_list"))), "tab_close")
bad = rpc("tools/call", {"name": "nope", "arguments": {}})
check("error" in bad, "unknown tool is an error")
p.stdin.close(); p.wait(5)
sys.exit(1 if check.failed else 0)
EOF
[ $? = 0 ] || fail=1

echo "== browser closed: a clear message, not a hang"
for p in $(pgrep -u "$(id -u)" -f -- "-profile $BH/profile"); do kill "$p"; done
sleep 3
out=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"tabs_list","arguments":{}}}' | timeout 10 "$PY39" "$ROOT/bridge/mcp.py")
echo "$out" | grep -q "Claude Browser is not running" && ok "clear error when the browser is closed" || { bad "closed-browser error"; echo "$out"; }

echo "== install.sh remove"
bash "$ROOT/install.sh" remove > "$T/remove.log" 2>&1 && ok "remove exit 0" || bad "remove"
[ ! -e "$FAKE/Applications/Claude Browser.app" ] && [ ! -e "$FAKE/Library/Application Support/Mozilla/NativeMessagingHosts/claude_bridge.json" ] && [ -d "$BH/profile" ] \
  && ok "remove takes the app and manifest, keeps the profile" || bad "remove leftovers"
grep -q "mcp remove --scope user bridge" "$CLAUDE_LOG" && ok "claude mcp remove" || bad "claude mcp remove"

echo
[ $fail = 0 ] && echo "ALL PASS ($T)" || echo "SOMETHING FAILED (logs in $T)"
exit $fail
