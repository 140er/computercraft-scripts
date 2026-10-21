"""Host-agnostic Minecraft RCON client.

Vanilla 1.21.1 reads one 1460-byte buffer per command and closes the
socket when that read is not exactly one packet (RconClient buf length
and the length check in run). Replies longer than 4096 bytes are split
by sendCmdResponse. This client sends one packet, then reads every chunk.
"""

import socket
import struct
import threading
import time
from pathlib import Path

from .errors import FixtureError

AUTH = 3
AUTH_RESPONSE = 2
EXEC = 2
RESPONSE = 0
MAX_COMMAND_BYTES = 1400
FRAGMENT_BYTES = 4096


class RconError(FixtureError):
    pass


def _utc_stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Client:
    def __init__(self, host, port, password, log_path, timeout=30, fragment_timeout=1.0):
        if not host or host.strip() == "":
            raise RconError("RCON host is required")
        self.host = host
        self.port = int(port)
        self.password = str(password)
        self.timeout = float(timeout)
        self.fragment_timeout = float(fragment_timeout)
        self.log_path = Path(log_path)
        self._sock = None
        self._next = 0
        self._lock = threading.Lock()

    def close(self):
        sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def marker(self, text):
        self._write_log("%s # %s\n" % (_utc_stamp(), text.replace("\n", " ")))

    def command(self, text, timeout=None):
        if not isinstance(text, str) or text == "" or any(char in text for char in "\r\n\x00"):
            raise RconError("command must be a single line")
        if len(text.encode("utf-8")) > MAX_COMMAND_BYTES:
            raise RconError("command exceeds the vanilla 1460-byte RCON read")
        with self._lock:
            if self._sock is None:
                self._connect()
            try:
                reply = self._exchange(text, timeout if timeout is not None else self.timeout)
            except OSError as exc:
                self.close()
                raise RconError("RCON connection failed: %s" % exc) from exc
            self._write_log("%s > %s\n%s\n" % (_utc_stamp(), text, reply))
            return reply

    def _connect(self):
        sock = socket.create_connection((self.host, self.port), self.timeout)
        sock.settimeout(self.timeout)
        self._sock = sock
        try:
            ident = self._ident()
            self._send(ident, AUTH, self.password)
            rid, kind, _body = self._recv()
            if rid == -1:
                raise RconError("RCON authentication failed")
            if not (kind == AUTH_RESPONSE and rid == ident):
                rid, kind, _body = self._recv()
                if rid == -1 or kind != AUTH_RESPONSE or rid != ident:
                    raise RconError("RCON authentication did not complete")
        except Exception:
            self.close()
            raise

    def _exchange(self, text, timeout):
        self._sock.settimeout(timeout)
        ident = self._ident()
        self._send(ident, EXEC, text)
        parts = []
        while True:
            rid, kind, body = self._recv()
            if rid != ident or kind != RESPONSE:
                raise RconError("unexpected RCON packet id %s type %s" % (rid, kind))
            parts.append(body)
            if len(body) < FRAGMENT_BYTES:
                break
            self._sock.settimeout(self.fragment_timeout)
            try:
                pending = self._sock.recv(1, socket.MSG_PEEK)
            except socket.timeout:
                break
            if not pending:
                break
            self._sock.settimeout(timeout)
        return b"".join(parts).decode("utf-8", "replace")

    def _ident(self):
        self._next = self._next + 1
        if self._next > 0x7FFFFFFF:
            self._next = 1
        return self._next

    def _send(self, ident, kind, text):
        payload = text.encode("utf-8")
        body = struct.pack("<ii", ident, kind) + payload + b"\x00\x00"
        self._sock.sendall(struct.pack("<i", len(body)) + body)

    def _recv(self):
        length = struct.unpack("<i", self._read_exact(4))[0]
        if length < 10 or length > 10 + FRAGMENT_BYTES + 16:
            raise RconError("invalid RCON packet length %s" % length)
        data = self._read_exact(length)
        ident, kind = struct.unpack("<ii", data[:8])
        if len(data) < 10 or data[-2:] != b"\x00\x00":
            raise RconError("truncated RCON packet")
        return ident, kind, data[8:-2]

    def _read_exact(self, size):
        chunks = []
        remaining = size
        while remaining:
            part = self._sock.recv(remaining)
            if not part:
                raise RconError("RCON closed the connection")
            chunks.append(part)
            remaining -= len(part)
        return b"".join(chunks)

    def _write_log(self, text):
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(text)
