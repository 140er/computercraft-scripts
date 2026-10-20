import json
import socket
import struct
import sys


def run(request):
    def send(kind, body):
        data = body.encode("utf-8")
        connection.sendall(struct.pack("<iii", len(data) + 10, 11, kind) + data + b"\0\0")

    def read_exact(size):
        result = b""
        while len(result) < size:
            part = connection.recv(size - len(result))
            if not part:
                raise RuntimeError("RCON closed the connection")
            result += part
        return result

    def receive():
        size = struct.unpack("<i", read_exact(4))[0]
        if not 10 <= size <= 1048576:
            raise RuntimeError("Invalid RCON packet size")
        data = read_exact(size)
        identity, kind = struct.unpack("<ii", data[:8])
        return identity, kind, data[8:-2].decode("utf-8")

    with socket.create_connection(("127.0.0.1", request["port"]), timeout=15) as connection:
        send(3, request["password"])
        identity, kind, _ = receive()
        if kind != 2:
            identity, kind, _ = receive()
        if identity == -1:
            raise RuntimeError("RCON authentication failed")
        send(2, request["command"])
        return receive()[2]


if __name__ == "__main__":
    print(run(json.load(sys.stdin)))
