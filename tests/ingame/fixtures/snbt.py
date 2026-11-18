"""Parser for the SNBT returned by Minecraft data commands."""


class SnbtError(ValueError):
    pass


def parse(text):
    parser = _Parser(text)
    value = parser.value()
    parser.skip()
    if parser.i < len(parser.text):
        raise SnbtError("trailing SNBT at %s" % parser.i)
    return value


def parse_data_reply(text):
    """Parse the first compound or list in a data-command reply."""
    starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
    if not starts:
        return None
    return parse(text[min(starts):])


def item_rows(value):
    """Return slot rows from a block-entity compound or an Items list."""
    if isinstance(value, list):
        items = value
        block_id = None
    elif isinstance(value, dict):
        items = value.get("Items", value.get("items", []))
        block_id = value.get("id")
        if not isinstance(items, list):
            items = []
    else:
        return None, []
    rows = []
    for entry in items:
        if not isinstance(entry, dict) or "id" not in entry:
            continue
        count = entry.get("count", entry.get("Count", 1))
        slot = entry.get("Slot", entry.get("slot"))
        if isinstance(count, bool) or not isinstance(count, (int, float)):
            continue
        if slot is not None and (isinstance(slot, bool) or not isinstance(slot, (int, float))):
            continue
        components = entry.get("components")
        rows.append({
            "slot": None if slot is None else int(slot),
            "id": str(entry["id"]),
            "count": int(count),
            "components": components if isinstance(components, dict) and components else None,
        })
    rows.sort(key=lambda row: (row["slot"] is None, row["slot"] if row["slot"] is not None else 0, row["id"]))
    return (str(block_id) if isinstance(block_id, str) else None), rows


class _Parser:
    def __init__(self, text):
        self.text = text
        self.n = len(text)
        self.i = 0

    def peek(self):
        return self.text[self.i] if self.i < self.n else ""

    def skip(self):
        while self.i < self.n and self.text[self.i] in " \t\r\n":
            self.i += 1

    def value(self):
        self.skip()
        char = self.peek()
        if char == "{":
            return self.compound()
        if char == "[":
            return self.sequence()
        if char in "\"'":
            return self.quoted()
        return self.primitive()

    def compound(self):
        self._eat("{")
        out = {}
        self.skip()
        if self.peek() == "}":
            self.i += 1
            return out
        while True:
            self.skip()
            key = self.quoted() if self.peek() in "\"'" else self.raw_key()
            self.skip()
            self._eat(":")
            out[key] = self.value()
            self.skip()
            if self.peek() == ",":
                self.i += 1
                continue
            self._eat("}")
            return out

    def sequence(self):
        self._eat("[")
        self.skip()
        if self.peek() == "]":
            self.i += 1
            return []
        # [B;1b,2b], [I;1,2] and [L;1L,2L] are typed arrays.
        saved = self.i
        if self.peek() in "BILbil" and self.i + 1 < self.n and self.text[self.i + 1] == ";":
            self.i += 2
            kind = "array"
        else:
            self.i = saved
            kind = "list"
        if self.peek() == "]":
            self.i += 1
            return []
        values = []
        while True:
            values.append(self.value())
            self.skip()
            if self.peek() == ",":
                self.i += 1
                continue
            self._eat("]")
            return values if kind == "list" else values

    def quoted(self):
        quote = self.text[self.i]
        self.i += 1
        chars = []
        while self.i < self.n:
            char = self.text[self.i]
            self.i += 1
            if char == "\\":
                if self.i >= self.n:
                    raise SnbtError("truncated string escape")
                esc = self.text[self.i]
                self.i += 1
                chars.append({"n": "\n", "t": "\t", "\\": "\\", "\"": "\"", "'": "'"}.get(esc, esc))
                continue
            if char == quote:
                return "".join(chars)
            chars.append(char)
        raise SnbtError("unterminated string")

    def raw_key(self):
        start = self.i
        while self.i < self.n and self.text[self.i] not in " \t\r\n:{},[]":
            self.i += 1
        if self.i == start:
            raise SnbtError("missing key at %s" % start)
        return self.text[start:self.i]

    def primitive(self):
        start = self.i
        while self.i < self.n and self.text[self.i] not in " \t\r\n,}]":
            self.i += 1
        token = self.text[start:self.i]
        if token == "":
            raise SnbtError("missing value at %s" % start)
        if token == "true":
            return True
        if token == "false":
            return False
        return _number_or_string(token)

    def _eat(self, char):
        self.skip()
        if self.peek() != char:
            raise SnbtError("expected %s at %s" % (char, self.i))
        self.i += 1


def _number_or_string(token):
    suffix = ""
    body = token
    if len(token) >= 2 and token[-1] in "bBsSlLfFdD" and token[-2].isdigit():
        suffix = token[-1].lower()
        body = token[:-1]
    try:
        if "." in body or "e" in body.lower() or suffix in ("f", "d"):
            return float(body)
        return int(body, 10)
    except ValueError:
        return token
