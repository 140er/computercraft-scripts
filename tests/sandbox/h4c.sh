#!/bin/sh
# Gate A for H4c. One CraftOS-PC 2.8.3 computer at 1000000 bytes.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cache=${XDG_CACHE_HOME:-"$HOME/.cache"}/computercraft-sandbox/craftos-2.8.3-linux
image=$cache/CraftOS-PC.x86_64.AppImage
app=$cache/squashfs-root/AppRun
rom=$cache/squashfs-root/usr/share/craftos
sum=f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c
mkdir -p "$cache"
if [ ! -x "$app" ]; then
  if [ ! -f "$image" ]; then
    curl -fsSL -o "$image" https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC.x86_64.AppImage
  fi
  actual=$(sha256sum "$image" | awk '{print $1}')
  if [ "$actual" != "$sum" ]; then
    echo "CraftOS-PC archive checksum mismatch." >&2
    exit 1
  fi
  chmod +x "$image"
  (cd "$cache" && "$image" --appimage-extract)
  chmod +x "$app"
fi
version=$("$app" --version | head -n 1)
if [ "$version" != "CraftOS-PC v2.8.3" ]; then
  echo "Use CraftOS-PC v2.8.3 AppImage." >&2
  exit 1
fi
run=$(mktemp -d)
mkdir -p "$run/config" "$run/rom" "$run/computer/0/lib/stubs"
cp "$rom/bios.lua" "$run/rom/bios.lua"
cp -a "$rom/rom" "$run/rom/rom"
printf '%s\n' '{"standardsMode":true,"computerSpaceLimit":1000000,"checkUpdates":false,"http_enable":false,"keepOpenOnShutdown":false,"logErrors":true}' > "$run/config/global.json"
for f in storage-ledger.lua storage-buffer.lua storage-view.lua storage-host.lua; do
  cp "$root/$f" "$run/computer/0/$f"
done
cp "$root/lib/stubs/h4c_dep.lua" "$run/computer/0/lib/stubs/h4c_dep.lua"
cp "$root/tests/h4c-sandbox.lua" "$run/computer/0/startup.lua"
export SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=dummy
"$app" --headless --directory "$run" --rom "$run/rom" --id 0 > "$run/stdout.log" 2> "$run/stderr.log" &
pid=$!
result=$run/computer/0/sandbox-result.json
i=0
while [ "$i" -lt 150 ]; do
  if [ -f "$result" ]; then
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.2
  i=$((i + 1))
done
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
if [ -s "$run/stderr.log" ]; then
  echo "Emulator stderr:" >&2
  cat "$run/stderr.log" >&2
  exit 1
fi
if [ ! -f "$result" ]; then
  echo "Sandbox FAIL: missing result" >&2
  cat "$run/stdout.log" >&2 || true
  exit 1
fi
echo "Artifacts: $run"
cat "$result"
echo
lua5.2 -e "local f=assert(io.open([[$result]])); local s=f:read('*a'); f:close(); assert(s:find('\"ok\":true', 1, true), s); assert(s:find('\"capacity\":1000000', 1, true), s); assert(s:find('\"used\":800000', 1, true), s); print('Sandbox PASS')"
