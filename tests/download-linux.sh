#!/bin/bash
# The download branch of install.sh, on Linux: no Firefox Developer Edition
# in the fake home, so install.sh fetches Mozilla's real .dmg, checks it
# against SHA512SUMS and copies the app out. hdiutil is 7z here (Linux
# cannot mount a .dmg). The Mac Firefox cannot run on Linux, so the test
# stops being meaningful after the copy: it checks the copy, not the start.
set -u
T=$(mktemp -d /tmp/cb-dl.XXXX)
FAKE="$T/home"; STUB="$T/stub"
mkdir -p "$FAKE" "$STUB"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
printf '#!/bin/sh\necho Darwin\n' > "$STUB/uname"
printf '#!/bin/sh\nexit 0\n' > "$STUB/xattr"
printf '#!/bin/sh\nexit 0\n' > "$STUB/open"
printf '#!/bin/sh\nexit 0\n' > "$STUB/claude"
printf '#!/bin/sh\nexec cp -R "$1" "$2"\n' > "$STUB/ditto"
cat > "$STUB/hdiutil" <<'EOF'
#!/bin/sh
# attach -nobrowse -readonly -noautoopen -mountpoint MNT DMG  |  detach MNT -quiet
[ "$1" = attach ] || exit 0
eval "mnt=\${$(($# - 1))}"; eval "dmg=\${$#}"
x=$(mktemp -d)
7z x -y -o"$x" "$dmg" >/dev/null 2>&1
app=$(find "$x" -maxdepth 3 -name '*.app' -type d | head -1)
[ -n "$app" ] || exit 1
mv "$app" "$mnt/"
EOF
chmod +x "$STUB"/*
# a 3-second check instead of 60: the Mac browser cannot start here anyway
sed 's#check.py" 60#check.py" 3#' "$ROOT/install.sh" > "$T/install.sh"
cp -R "$ROOT/extension" "$ROOT/bridge" "$ROOT/profile" "$T/"
HOME="$FAKE" PATH="$STUB:$PATH" bash "$T/install.sh" 2>&1 | grep -v '^#' | tail -25
app="$FAKE/Applications/Firefox Developer Edition.app"
[ -x "$app/Contents/MacOS/firefox" ] && echo "PASS  Mozilla's .dmg checked and the app copied to ~/Applications" || echo "FAIL  no app after download"
grep -q "Firefox Developer Edition.app/Contents/MacOS/firefox" "$FAKE/Applications/Claude Browser.app/Contents/MacOS/claude-browser" && echo "PASS  launcher points at the downloaded app" || echo "FAIL  launcher"
[ -f "$FAKE/Applications/Claude Browser.app/Contents/Resources/browser.icns" ] && echo "PASS  real Firefox icon copied" || echo "FAIL  icon"

echo "== a tampered download is refused"
printf '#!/bin/sh\nexec /usr/bin/core_perl/shasum "$@" | sed "s/^./0/"\n' > "$STUB/shasum"; chmod +x "$STUB/shasum"
rm -rf "$FAKE"; mkdir -p "$FAKE"
out=$(HOME="$FAKE" PATH="$STUB:$PATH" bash "$T/install.sh" 2>&1)
echo "$out" | grep -q "nu se potrivește cu suma de control" && [ ! -e "$FAKE/Applications/Firefox Developer Edition.app" ] \
  && echo "PASS  checksum mismatch stops the install, nothing copied" || { echo "FAIL  tampered download"; echo "$out" | tail -3; }
rm -rf "$T"
