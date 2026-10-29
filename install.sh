#!/bin/bash
# Claude Bridge for macOS (Előd's): lets Claude Code use a browser with
# your own sign-ins: tabs, reading pages, clicking, typing, screenshots.
#
#   bash install.sh           install, or update an older install
#   bash install.sh remove    take it out again (your browser profile stays)
#
# What it sets up:
#   - Firefox Developer Edition, if it is not there yet: Mozilla's own .dmg,
#     checked against Mozilla's SHA512SUMS before it is copied anywhere;
#   - ~/Library/Application Support/ClaudeBridge: the extension, the bridge
#     and a browser profile of its own;
#   - ~/Applications/Claude Browser.app, which opens Firefox on that profile;
#   - the native-messaging manifest that lets the extension reach the bridge;
#   - the `bridge` MCP server in Claude Code (user scope).
#
# Written for the bash 3.2 that ships with macOS.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SUP="$HOME/Library/Application Support"
BH="$SUP/ClaudeBridge"
PROF="$BH/profile"
NMH="$SUP/Mozilla/NativeMessagingHosts"
APP="$HOME/Applications/Claude Browser.app"
EXT_ID="claude-bridge@elod"
FF_NAME="Firefox Developer Edition.app"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '\nEroare: %s\n' "$*" >&2; exit 1; }
# a value inside single quotes, safe for a shell script whatever it holds
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

[ "$(uname -s)" = Darwin ] || die "instalatorul ăsta e pentru macOS."

find_claude() {
    for c in "$(command -v claude 2>/dev/null || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
             /opt/homebrew/bin/claude /usr/local/bin/claude; do
        if [ -n "$c" ] && [ -x "$c" ]; then CLAUDE="$c"; return 0; fi
    done
    return 1
}

if [ "${1:-}" = remove ]; then
    step "Scot Claude Bridge"
    rm -f "$NMH/claude_bridge.json"
    rm -rf "$APP" "$BH/extension" "$BH/bridge" "$BH/run"
    rm -f "$PROF/extensions/$EXT_ID"
    if find_claude; then "$CLAUDE" mcp remove --scope user bridge >/dev/null 2>&1 || true; fi
    say "Gata. Profilul browserului (cu loginurile tale) a rămas în:"
    say "  $PROF"
    say "Dacă nu-l mai vrei: rm -rf \"$BH\""
    exit 0
fi
[ -z "${1:-}" ] || die "nu știu ce e „$1”. Folosește: bash install.sh   sau   bash install.sh remove"

for f in extension/manifest.json extension/background.js extension/page.js bridge/host.py bridge/mcp.py bridge/paths.py bridge/check.py profile/user.js; do
    [ -f "$HERE/$f" ] || die "lipsește $f din folderul instalatorului. Dezarhivează tot folderul și rulează install.sh din el."
done

# ── Python ───────────────────────────────────────────────────────────────
step "Caut Python 3"
PY=""
for p in "$(command -v python3 2>/dev/null || true)" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    [ -n "$p" ] && [ -x "$p" ] || continue
    if "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
        PY="$p"; break
    fi
done
if [ -z "$PY" ]; then
    die "nu găsesc Python 3. Rulează în Terminal:   xcode-select --install
apasă Install în fereastra care apare, așteaptă să termine, apoi rulează din nou install.sh."
fi
say "$PY ($("$PY" -c 'import platform; print(platform.python_version())'))"

# ── Firefox Developer Edition ────────────────────────────────────────────
step "Caut Firefox Developer Edition"
FF=""
for d in "/Applications/$FF_NAME" "$HOME/Applications/$FF_NAME"; do
    if [ -x "$d/Contents/MacOS/firefox" ]; then FF="$d"; break; fi
done

if [ -z "$FF" ]; then
    say "Nu e instalat. Îl iau de la Mozilla."
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        'https://download.mozilla.org/?product=firefox-devedition-latest-ssl&os=osx&lang=en-US') \
        || die "nu pot ajunge la mozilla.org. Verifică internetul și încearcă iar."
    case "$url" in
        https://*/pub/devedition/releases/*/mac/en-US/*.dmg) ;;
        *) die "Mozilla a dat un link neașteptat ($url); nu instalez nimic." ;;
    esac
    base=${url%/mac/en-US/*}
    file=$(printf '%s' "${url##*/}" | sed 's/%20/ /g')

    tmp=$(mktemp -d)
    mnt="$tmp/mnt"
    cleanup() {
        if [ -d "$mnt" ]; then hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; fi
        rm -rf "$tmp"
    }
    trap cleanup EXIT

    curl -fL --progress-bar -o "$tmp/ff.dmg" "$url" || die "descărcarea s-a oprit. Încearcă iar."
    curl -fsSL -o "$tmp/SHA512SUMS" "$base/SHA512SUMS" || die "nu pot lua sumele de control de la Mozilla."
    want=$(awk -v f="mac/en-US/$file" '{ h = $1; $1 = ""; sub(/^ +/, ""); if ($0 == f) print h }' "$tmp/SHA512SUMS")
    got=$(shasum -a 512 "$tmp/ff.dmg" | awk '{ print $1 }')
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        die "fișierul descărcat nu se potrivește cu suma de control a lui Mozilla; nu-l instalez."
    fi
    say "Descărcat și verificat (SHA-512, $file)."

    mkdir -p "$mnt"
    hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$tmp/ff.dmg" >/dev/null \
        || die "nu pot deschide .dmg-ul."
    [ -d "$mnt/$FF_NAME" ] || die "în .dmg nu e $FF_NAME."
    if [ -w /Applications ]; then dest=/Applications; else dest="$HOME/Applications"; mkdir -p "$dest"; fi
    ditto "$mnt/$FF_NAME" "$dest/$FF_NAME" || die "nu pot copia Firefox în $dest."
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true
    FF="$dest/$FF_NAME"
fi
say "$FF"

# ── the bridge's own files ───────────────────────────────────────────────
step "Instalez extensia și bridge-ul"
mkdir -p "$BH"
chmod 700 "$BH"
rm -rf "$BH/extension" "$BH/bridge"
cp -R "$HERE/extension" "$HERE/bridge" "$BH/"
rm -rf "$BH/bridge/__pycache__"
# a download is marked as quarantined; these are only read by Firefox and Python
xattr -dr com.apple.quarantine "$BH/extension" "$BH/bridge" 2>/dev/null || true

# Firefox starts native hosts with a bare PATH, so the host names its Python
{
    printf '#!/bin/sh\n'
    printf 'exec %s %s\n' "$(q "$PY")" "$(q "$BH/bridge/host.py")"
} > "$BH/bridge/host"
chmod 755 "$BH/bridge/host"

mkdir -p "$NMH"
"$PY" - "$NMH/claude_bridge.json" "$BH/bridge/host" "$EXT_ID" <<'EOF'
import json, sys
out, host, ext = sys.argv[1:4]
with open(out, "w") as f:
    json.dump({"name": "claude_bridge", "description": "Claude Bridge (Előd)", "path": host,
               "type": "stdio", "allowed_extensions": [ext]}, f, indent=2)
EOF

# ── the browser profile ──────────────────────────────────────────────────
step "Pregătesc profilul browserului"
mkdir -p "$PROF/extensions"
cp "$HERE/profile/user.js" "$PROF/user.js"
# the extension as a proxy file: Firefox loads it from where it lies
printf '%s\n' "$BH/extension" > "$PROF/extensions/$EXT_ID"
say "$PROF"

# ── Claude Browser.app ───────────────────────────────────────────────────
step "Fac aplicația Claude Browser"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
icon=""
for i in "$FF/Contents/Resources/firefox.icns" "$FF/Contents/Resources/AppIcon.icns"; do
    if [ -f "$i" ]; then cp "$i" "$APP/Contents/Resources/browser.icns"; icon=browser; break; fi
done
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Browser</string>
  <key>CFBundleDisplayName</key><string>Claude Browser</string>
  <key>CFBundleIdentifier</key><string>ro.elod.claude-browser</string>
  <key>CFBundleExecutable</key><string>claude-browser</string>
  <key>CFBundleIconFile</key><string>$icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
</dict>
</plist>
EOF
{
    printf '#!/bin/sh\n'
    printf '# Firefox Developer Edition on the Claude Bridge profile\n'
    printf 'exec %s -profile %s "$@"\n' "$(q "$FF/Contents/MacOS/firefox")" "$(q "$PROF")"
} > "$APP/Contents/MacOS/claude-browser"
chmod 755 "$APP/Contents/MacOS/claude-browser"
touch "$APP"
say "$APP"

# ── Claude Code ──────────────────────────────────────────────────────────
step "Îl leg de Claude Code"
MCP_OK=0
if find_claude; then
    "$CLAUDE" mcp remove --scope user bridge >/dev/null 2>&1 || true
    if "$CLAUDE" mcp add --scope user bridge -- "$PY" "$BH/bridge/mcp.py"; then MCP_OK=1; fi
fi
if [ "$MCP_OK" = 0 ]; then
    say "Nu am găsit comanda claude. După ce instalezi Claude Code, rulează:"
    say "  claude mcp add --scope user bridge -- $(q "$PY") $(q "$BH/bridge/mcp.py")"
fi

# ── does it work? ────────────────────────────────────────────────────────
step "Pornesc Claude Browser și verific legătura"
open "$APP"
if "$PY" "$BH/bridge/check.py" 60; then
    say ""
    say "Gata, merge. Deschide Claude Browser din ~/Applications (sau Spotlight),"
    say "intră în conturile tale acolo, apoi repornește Claude Code și cere-i"
    say "de exemplu: „deschide gmail.com în browser și spune-mi ce e nou”."
else
    say ""
    say "Browserul nu a răspuns în 60 de secunde. Dacă tocmai s-a deschis prima"
    say "oară, închide-l (⌘Q), deschide-l din nou și rulează:"
    say "  $(q "$PY") $(q "$BH/bridge/check.py") 30"
    exit 1
fi
