"""Parse the data subset emitted by textutils.serialize, without executing Lua."""
import re

TOKEN = re.compile(r'\s*(?:(--[^\n]*\n)|("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([A-Za-z_]\w*)|([{}\[\]=,;]))')


def parse(text):
    tokens, pos = [], 0
    while pos < len(text.rstrip()):
        match = TOKEN.match(text, pos)
        if not match:
            raise ValueError("Unsupported serialized Lua data")
        pos = match.end()
        if not match[1]:
            tokens.append(next(v for v in match.groups()[1:] if v is not None))
    index = 0

    def string(token):
        def escape(m):
            s = m[1]
            if s.isdigit(): return chr(int(s))
            return {"n": "\n", "r": "\r", "t": "\t", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}.get(s, s)
        return re.sub(r'\\(\d{1,3}|.)', escape, token[1:-1], flags=re.S)

    def take(expected=None):
        nonlocal index
        if index >= len(tokens): raise ValueError("Truncated Lua data")
        token = tokens[index]
        index += 1
        if expected and token != expected: raise ValueError("Malformed Lua data")
        return token

    def value():
        nonlocal index
        token = take()
        if token == "{":
            out, seq = {}, 1
            while index < len(tokens) and tokens[index] != "}":
                if tokens[index] == "[":
                    take("["); key = str(value()); take("]"); take("=")
                elif index + 1 < len(tokens) and tokens[index + 1] == "=":
                    key = take(); take("=")
                else:
                    key = str(seq); seq += 1
                out[key] = value()
                if index < len(tokens) and tokens[index] in (",", ";"): take()
            take("}")
            return out
        if token[0] in "\"'": return string(token)
        if token in ("true", "false", "nil"): return {"true": True, "false": False, "nil": None}[token]
        try: return float(token) if any(c in token for c in ".eE") else int(token)
        except ValueError: raise ValueError("Unsupported Lua value") from None

    result = value()
    if index != len(tokens): raise ValueError("Trailing Lua data")
    return result
