#!/bin/sh
# Gate A for A1 on Linux. One CraftOS-PC 2.8.3 computer, no GPS, 1000000 byte disk.
# Same AppImage checksum as tests/sandbox/run.ps1 on PR 59.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/computercraft-sandbox/craftos-2.8.3-linux"
IMAGE="$CACHE/CraftOS-PC.x86_64.AppImage"
ROOTFS="$CACHE/squashfs-root"
APP="$ROOTFS/AppRun"
ROM="$ROOTFS/usr/share/craftos"
SUM=f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c
URL=https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC.x86_64.AppImage

mkdir -p "$CACHE"
if [ ! -x "$APP" ]; then
  if [ ! -f "$IMAGE" ]; then
    echo "Downloading CraftOS-PC v2.8.3 AppImage..."
    curl -fsSL -o "$IMAGE" "$URL"
  fi
  actual=$(sha256sum "$IMAGE" | awk '{print $1}')
  if [ "$actual" != "$SUM" ]; then
    echo "CraftOS-PC archive checksum mismatch." >&2
    exit 1
  fi
  chmod +x "$IMAGE"
  rm -rf "$ROOTFS"
  (cd "$CACHE" && "$IMAGE" --appimage-extract > extract.log)
fi

RUN=$(mktemp -d)
cleanup() { rm -rf "$RUN"; }
trap cleanup EXIT
mkdir -p "$RUN/config" "$RUN/rom" "$RUN/computer/0/lib/stubs" "$RUN/computer/0/tests"
cp "$ROM/bios.lua" "$RUN/rom/bios.lua"
cp -a "$ROM/rom" "$RUN/rom/rom"
printf '%s\n' '{"standardsMode":true,"computerSpaceLimit":1000000,"checkUpdates":false,"http_enable":false,"keepOpenOnShutdown":false,"logErrors":true}' > "$RUN/config/global.json"
DISK="$RUN/computer/0"
cp "$ROOT/ar-planner.lua" "$DISK/ar-planner.lua"
cp "$ROOT/lib/stubs/a1_planner_core.lua" "$DISK/lib/stubs/a1_planner_core.lua"
cp "$ROOT/lib/stubs/a1_chat.lua" "$DISK/lib/stubs/a1_chat.lua"
cp "$ROOT/tests/a1-checks.lua" "$DISK/tests/a1-checks.lua"
cp "$ROOT/tests/sandbox/a1-driver.lua" "$DISK/a1-driver.lua"
printf '%s\n' "shell.run('a1-driver.lua')" > "$DISK/startup.lua"

export SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=dummy
"$APP" --headless --directory "$RUN" --rom "$RUN/rom" --id 0 > "$RUN/stdout.log" 2> "$RUN/stderr.log" &
pid=$!
i=0
while [ "$i" -lt 60 ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  if [ -f "$DISK/sandbox-result.json" ]; then
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    break
  fi
  sleep 1
  i=$((i + 1))
done
wait "$pid" 2>/dev/null || true
if [ -s "$RUN/stderr.log" ] && ! grep -qx 'Terminated' "$RUN/stderr.log"; then
  echo "Emulator stderr:" >&2
  cat "$RUN/stderr.log" >&2
  exit 1
fi
if [ ! -f "$DISK/sandbox-result.json" ]; then
  echo "A1 sandbox FAIL: missing result" >&2
  cat "$RUN/stdout.log" >&2 || true
  exit 1
fi
lua5.2 - "$DISK/sandbox-result.json" <<'EOF'
local f = assert(io.open(arg[1]))
local t = f:read("*a")
f:close()
assert(t:find('"ok":true', 1, true), t)
local cap = t:match('"capacity":(%d+)')
assert(cap == "1000000", "capacity " .. tostring(cap))
print(t)
EOF
echo "A1 sandbox PASS"
mkdir -p "$ROOT/docs/evidence/a1"
cp "$DISK/sandbox-result.json" "$ROOT/docs/evidence/a1/sandbox-result.json"
cp "$RUN/stdout.log" "$ROOT/docs/evidence/a1/sandbox-stdout.txt"
