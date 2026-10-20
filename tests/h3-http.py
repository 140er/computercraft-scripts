import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--log', required=True)
    parser.add_argument('--port', type=int, required=True)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--ready-file')
    args = parser.parse_args()
    root = Path(args.root).resolve()
    active = set()
    lock = threading.Lock()

    def record(value):
        with lock, open(args.log, 'a', encoding='utf-8') as output:
            output.write(json.dumps(dict(atMs=time.time_ns() // 1000000, **value)) + '\n')

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            url = urlparse(self.path)
            query = parse_qs(url.query)
            token = query.get('token', [''])[0]
            if url.path == '/status':
                with lock:
                    body = json.dumps(dict(active=token in active, token=token)).encode()
            else:
                name = url.path.removeprefix('/asset/')
                path = root / name
                if path.parent != root or path.suffix != '.lua' or not path.is_file():
                    self.send_error(404)
                    return
                delay = min(30, max(0, float(query.get('delay', ['0'])[0])))
                with lock:
                    active.add(token)
                record(dict(event='start', token=token, file=name, delay=delay))
                try:
                    time.sleep(delay)
                    body = path.read_bytes().replace(b'\r\n', b'\n')
                finally:
                    with lock:
                        active.discard(token)
                    record(dict(event='end', token=token, file=name))
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    ready = dict(event='listening', port=server.server_port, bind=args.bind)
    record(ready)
    if args.ready_file:
        ready_path = Path(args.ready_file)
        temporary = ready_path.with_suffix('.tmp')
        temporary.write_text(json.dumps(ready), encoding='utf-8')
        temporary.replace(ready_path)
    server.serve_forever()


if __name__ == '__main__':
    main()
