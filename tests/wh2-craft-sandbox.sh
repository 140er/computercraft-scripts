#!/bin/sh
# CraftOS-PC 2.8.3 Gate A for the craft item. One computer, 1000000 byte disk.
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cache="${CRAFTOS_CACHE:-$HOME/.cache/computercraft-sandbox}/craftos-2.8.3-linux"
image="$cache/CraftOS-PC.x86_64.AppImage"
app="$cache/squashfs-root/AppRun"
sum="f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c"
mkdir -p "$cache"
if [ ! -x "$app" ]; then
  if [ ! -f "$image" ]; then
    curl -fsSL -o "$image" "https://github.com/MCJack123/craftos2/releases/download/v2.8.3/CraftOS-PC.x86_64.AppImage"
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
  echo "Use CraftOS-PC v2.8.3 AppImage (squashfs-root/AppRun)." >&2
  exit 1
fi
run=$(mktemp -d)
mkdir -p "$run/config" "$run/rom" "$run/computer/0/lib/stubs"
rom="$cache/squashfs-root/usr/share/craftos"
cp "$rom/bios.lua" "$run/rom/bios.lua"
cp -a "$rom/rom" "$run/rom/rom"
printf '%s\n' '{"standardsMode":true,"computerSpaceLimit":1000000,"checkUpdates":false,"http_enable":false,"keepOpenOnShutdown":false,"logErrors":true}' > "$run/config/global.json"
for name in wh2-craft.lua wh2-recipes.lua craft.lua factory.lua; do
  cp "$root/$name" "$run/computer/0/$name"
done
cp "$root/lib/stubs/craft_dep.lua" "$run/computer/0/lib/stubs/craft_dep.lua"
cp "$root/lib/stubs/craft_dep.lua" "$run/computer/0/craft_dep.lua"
cp "$root/tests/wh2-craft-checks.lua" "$run/computer/0/wh2-craft-checks.lua"
cp "$root/tests/wh2-craft-runtime.lua" "$run/computer/0/wh2-craft-runtime.lua"
printf '%s\n' 'shell.run("wh2-craft-runtime.lua")' > "$run/computer/0/startup.lua"
export SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=dummy
# Headless CraftOS keeps the process after os.shutdown. Stop it when the report exists.
"$app" --headless --directory "$run" --rom "$run/rom" --id 0 > "$run/stdout.log" 2> "$run/stderr.log" &
pid=$!
deadline=$(( $(date +%s) + 120 ))
while [ ! -s "$run/computer/0/sandbox-result.json" ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "craft sandbox timed out before sandbox-result.json" >&2
    exit 1
  fi
  sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
fi
echo "Sandbox: $run"
if [ -s "$run/stderr.log" ]; then
  echo "Emulator stderr:"
  cat "$run/stderr.log"
  exit 1
fi
if [ ! -f "$run/computer/0/sandbox-result.json" ]; then
  echo "missing sandbox-result.json" >&2
  cat "$run/stdout.log" >&2 || true
  exit 1
fi
cat "$run/computer/0/sandbox-result.json"
echo
python3 - "$run/computer/0/sandbox-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if not result.get("ok"):
    sys.exit("craft sandbox failed: " + "; ".join(result.get("errors") or []))
print("capacity", result.get("capacity"), "free", result.get("free"))
PY
exit 0
