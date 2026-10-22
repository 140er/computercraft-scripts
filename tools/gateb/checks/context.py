import json
from pathlib import Path
import re
import subprocess
import time

from .lua_data import parse
from .model import Blocked, values

HTTP_UPDATE = '''local original=http.get;local requests,failures=0,0
  http.get=function(...) requests=requests+1;local r,e,f=original(...)
    if not r or r.getResponseCode()~=200 then failures=failures+1 end;return r,e,f end
  local ok,ran=pcall(shell.run,"install","update");http.get=original
  if not ok then error(ran) end
  return {ran=ran,requests=requests,failures=failures}'''

SECRET_FIELD = re.compile(r"^(?:keys?|secret|token|pair(?:ing)?_?code|private.*)$", re.I)


def sanitize(value):
    if isinstance(value, dict):
        return {str(k): "[redacted]" if SECRET_FIELD.fullmatch(str(k)) else sanitize(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [sanitize(v) for v in value]
    if isinstance(value, str):
        value = re.sub(r"(?i)(pair\s*code\s*[:=]?\s*)\d{6}", r"\1[redacted]", value)
        return re.sub(r"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])", "[redacted]", value)
    return value


class Context:
    def __init__(self, runtime, run, manifest, output, commit, tick_rate=20, interval=.5):
        self.runtime, self.run, self.manifest = runtime, run, manifest
        self.output, self.commit = Path(output), commit
        self.tick_rate, self.interval = tick_rate, interval
        self.output.mkdir(parents=True, exist_ok=True)
        self.evidence = []

    def request(self, op, **kwargs):
        return self.runtime.request(self.run, {"op": op, **kwargs}, timeout=30)

    def cli(self, *args, timeout=180):
        command = ["python3", str(getattr(self, "runtime_dir", Path(__file__).resolve().parents[1]) / "world.py"), *map(str, args)]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        if completed.returncode:
            try:
                reason = json.loads(completed.stdout).get("error", "Runtime request failed")
            except (ValueError, AttributeError):
                reason = "Runtime process failed without an API v1 error"
            raise Blocked(f"Runtime {args[0]} failed: {sanitize(str(reason))[:500]}")
        try:
            return json.loads(completed.stdout)["result"]
        except (ValueError, KeyError):
            raise Blocked("Runtime CLI did not return API v1 JSON") from None

    def computer(self, name):
        for ident, info in self.manifest["computers"].items():
            if info.get("name") == name:
                return int(ident)
        raise Blocked(f"Template has no named computer {name}")

    def fixture(self, name):
        value = self.manifest.get("fixtures", {}).get(name, self.manifest.get(name))
        if value is None:
            raise Blocked(f"Template has no fixture {name}")
        return value

    def lua(self, name, code):
        result = self.request("lua", computer=self.computer(name), code=code)
        return result.get("values", [None])[0]

    def command(self, command):
        return self.request("command", command=command)

    def save(self):
        self.request("save")

    def record(self, name, value):
        path = self.output / name
        path.write_text(json.dumps(sanitize(value), indent=2, sort_keys=True) + "\n")
        if name not in self.evidence:
            self.evidence.append(name)
        return value

    def read_store(self, computer, path):
        candidates = []
        for suffix in ("", ".bak", ".tmp"):
            try:
                result = self.request("files", computer=self.computer(computer), path=path + suffix)
            except FileNotFoundError:
                continue
            content = result.get("content")
            if content:
                data = parse(content)
                if isinstance(data, dict) and data.get("schema") == 1:
                    candidates.append(data)
        return max(candidates, key=lambda v: v["generation"])["value"] if candidates else {}

    def state(self):
        mine = self.read_store("server", "so-data/mine/job")
        lumber = self.read_store("server", "so-data/lumber/job")
        workers = {}
        for name in ("miner1", "miner2", "lumber"):
            try:
                workers[str(self.computer(name))] = self.read_store(name, "so-journal")
            except Blocked:
                pass
        state = {"epoch": time.time(), "mine": mine, "lumber": lumber, "workers": workers}
        if self.tick_rate != 20: state["game_ms"] = self.game_clock()
        return state

    def sample(self, name, seconds, stop=None, observe=None):
        path, start, rows = self.output / name, time.monotonic(), []
        self.evidence.append(name)
        with path.open("w") as stream:
            while True:
                row = self.state()
                if observe: row.update(observe())
                stream.write(json.dumps(sanitize(row), separators=(",", ":")) + "\n")
                stream.flush()
                rows.append(row)
                if stop and stop(rows):
                    break
                remaining = seconds - (time.monotonic() - start)
                if remaining <= 0:
                    break
                time.sleep(min(self.interval, remaining))
        return rows

    def wait(self, predicate, seconds=30):
        start = time.monotonic()
        while True:
            try:
                result = predicate()
            except (RuntimeError, FileNotFoundError):
                result = None
            if result:
                return result
            if time.monotonic() - start >= seconds:
                return None
            time.sleep(self.interval)

    def game_seconds(self, seconds):
        return seconds * 20 / self.tick_rate

    def screen_input(self, role, text=None, button=None):
        payload = {"text": text} if text is not None else {"id": button}
        code = f'local s=assert(SO.mods.display.screen({json.dumps(role)})); s.input(textutils.unserializeJSON({json.dumps(json.dumps(payload))})); return true'
        return self.lua("server", code)

    def native(self, name):
        self.save()
        return self.request("turtle", computer=self.computer(name))

    def anchor(self, name, role):
        native = self.native(name)
        pos, facing = native.get("pos"), native.get("facing")
        if facing is None:
            facing = native.get("block", {}).get("Properties", {}).get("facing") if isinstance(native.get("block"), dict) else None
        if facing is None:
            facing = native.get("nbt", {}).get("facing")
        facing = {"north": "n", "east": "e", "south": "s", "west": "w", 0: "n", 1: "e", 2: "s", 3: "w"}.get(facing)
        if not pos or facing is None:
            raise Blocked("Native position and facing must be verified before add/re-anchor")
        self.record(f"native-{name}.json", native)
        self.screen_input(role, f"add {self.computer(name)} {' '.join(map(str, pos))} {facing}")

    def drops(self):
        for kind in ("ore", "fuel", "wood"):
            fixture = self.fixture(kind)
            point = {"kind": kind, "dim": 0, "side": fixture.get("side", "front"), **dict(zip(("x", "y", "z"), fixture["pos"]))}
            self.lua("server", "return SO.mods.drops.add(textutils.unserializeJSON(" + json.dumps(json.dumps(point)) + "))")

    def mining(self, start=True):
        self.drops()
        config = self.fixture("mine")
        self.screen_input("mining", "stop")
        state = self.state()
        if state["mine"].get("turtles"):
            raise Blocked("Mining fixture must start with no assigned workers; reset the private world")
        for text in (f"home {' '.join(map(str, config['home']))}", f"bottom {config['bottom']}",
                     f"length {config.get('length', 16)}", "mode thorough"):
            self.screen_input("mining", text)
        for name in ("miner1", "miner2"):
            self.anchor(name, "mining")
        if start: self.screen_input("mining", "start")

    def lumber(self, start=True):
        self.drops()
        config = self.fixture("farm")
        self.screen_input("lumber", "stop")
        self.screen_input("lumber", f"area {' '.join(map(str, config['area']))} {config['ground']}")
        chest = self.fixture("saplings")
        self.screen_input("lumber", f"saplings {' '.join(map(str, chest['pos']))} {chest.get('side', 'front')}")
        if not self.state()["lumber"].get("turtle"):
            self.anchor("lumber", "lumber")
        if start: self.screen_input("lumber", "start")

    def terminal(self, name):
        return self.request("terminal", computer=self.computer(name))

    def inventory(self, fixture):
        self.save()
        return self.request("chest", pos=self.fixture(fixture)["pos"])

    def count_items(self, fixture, suffix):
        items = self.inventory(fixture).get("items", [])
        return sum(int(i.get("count", i.get("Count", 0))) for i in values(items)
                   if str(i.get("id", i.get("name", ""))).endswith(suffix))

    def power(self, name, action):
        return self.request("power", computer=self.computer(name), action=action)

    def screenshot(self, name):
        result = self.cli("client", self.run, "shot")
        source = Path(result["path"] if isinstance(result, dict) else result)
        target = self.output / name
        target.write_bytes(source.read_bytes())
        self.evidence.append(name)

    def integrity(self, name):
        return self.lua(name, '''local p=dofile("so-proto.lua"); local function hash(path)
          if not fs.exists(path) then return false end
          local h=assert(fs.open(path,"r")); local s=h.readAll(); h.close(); return p.hex(p.sha256(s)) end
          local h=assert(fs.open(".so-files","r")); local files=textutils.unserialize(h.readAll()); h.close()
          local out={files={},pairing={}}; for _,path in ipairs(files) do out.files[path]=hash(path) end
          for _,path in ipairs({"so-keys","so-keys.bak","so-keys.tmp"}) do out.pairing[path]=hash(path) end
          return out''')

    def frame(self, name):
        frame = self.request("frame", computer=self.computer(name))
        if not isinstance(frame, dict) or not frame.get("buttons"):
            raise Blocked("Runtime must expose the latest received view.frame as GATEB_FRAME")
        return frame

    def click(self, name, button_id):
        frame = self.frame(name)
        buttons = [b for b in values(frame.get("buttons")) if b.get("id") == button_id]
        if not buttons:
            raise Blocked(f"Visible {button_id} button absent on {name} {frame.get('role', '')}")
        b = buttons[-1]
        if b["x"] < 1 or b["y"] < 1:
            raise Blocked("Button is outside the visible frame")
        if name == "wall":
            monitors = self.request("monitors", computer=self.computer(name))
            if not monitors: raise Blocked("No physical monitor")
            monitor, size = next(iter(monitors.items()))
            event, args = "monitor_touch", [monitor, b["x"], b["y"]]
        else:
            size = self.terminal(name)
            event, args = "mouse_click", [1, b["x"], b["y"]]
        if b["x"] + b.get("w", 1)-1 > size["width"] or b["y"] + b.get("h", 1)-1 > size["height"]:
            raise Blocked("Button is clipped outside physical display")
        self.request("input", computer=self.computer(name), event=event, args=args)
        time.sleep(self.interval * 2)
        return self.frame(name)

    def navigate(self, name, role):
        initial = self.frame(name)
        if initial.get("role") == role: return initial
        if any(b.get("id") == "map-back" for b in values(initial.get("buttons"))):
            self.click(name, "map-back")
        routes = {
            "status": (("status",), ("mine-back", "status"), ("lumber-back", "status")),
            "generic": (("generic",), ("more",), ("status", "more")),
            "mining": (("mining",), ("more", "mining"), ("status", "more", "mining")),
            "lumber": (("lumber",), ("more", "lumber"), ("status", "more", "lumber")),
            "shop": (("shop",), ("more", "shop"), ("status", "more", "shop")),
            "ar": (("ar",), ("more", "ar"), ("status", "more", "ar")),
            "map": (("map",), ("more", "map"), ("status", "more", "map")),
        }
        for route in routes[role]:
            try:
                for button in route: self.click(name, button)
                if self.frame(name).get("role") == role: return self.frame(name)
            except Blocked:
                continue
        raise Blocked(f"No visible navigation route from {name} to {role}")

    def game_clock(self):
        return self.lua("server", 'return SO and SO.now and SO.now() or os.clock() * 1000')

    def type_text(self, name, text):
        for char in text:
            self.request("input", computer=self.computer(name), event="char", args=[char])
        self.request("input", computer=self.computer(name), event="key", args=[257, False])

    def set_fuel(self, name, amount):
        self.power(name, "off")
        native = self.native(name)
        pos = " ".join(map(str, native["pos"]))
        self.command(f"data merge block {pos} {{Fuel:{amount}}}")
        self.save()
        proof = self.request("turtle", computer=self.computer(name))
        self.record(f"fuel-{name}-{amount}.json", proof)
        if proof.get("nbt", {}).get("Fuel") != amount:
            raise Blocked("Native low-fuel fixture was not applied")
        self.power(name, "on")
        if not self.wait(lambda: self.lua(name, "return turtle.getFuelLevel()") == amount, 30):
            raise Blocked("Worker did not load the native low-fuel fixture")
