import argparse
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', required=True)
    parser.add_argument('--seconds', type=int, required=True)
    args = parser.parse_args()
    base = os.environ['GATEB_URL'].rstrip('/')
    headers = {'X-Gateb-Token': os.environ['GATEB_TOKEN']}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(path, data=None):
        req = urllib.request.Request(base + '/runs/' + args.run + path, data=data, headers=headers)
        if data is not None:
            req.method = 'PUT'
        with opener.open(req, timeout=30) as response:
            return response.read()

    def put(name, value):
        request('/file?path=' + urllib.parse.quote(name, safe=''), value)

    directory = Path(tempfile.mkdtemp(prefix='h3-http-'))
    data = request('/tar?path=h3-http-assets')
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for member in archive.getmembers():
            target = (directory / member.name).resolve()
            if not target.is_relative_to(directory) or member.issym() or member.islnk():
                raise ValueError('Unexpected HTTP asset archive path')
        archive.extractall(directory)
    assets = directory / 'h3-http-assets'
    ready = directory / 'ready.json'
    log = directory / 'http.jsonl'
    process = subprocess.Popen([sys.executable, str(assets / 'h3-http.py'), '--root', str(assets),
                                '--log', str(log), '--port', '0', '--ready-file', str(ready)])
    try:
        deadline = time.monotonic() + 60
        while not ready.exists():
            if process.poll() is not None:
                raise RuntimeError('Box HTTP fixture exited')
            if time.monotonic() > deadline:
                raise TimeoutError('Box HTTP fixture did not start')
            time.sleep(.1)
        status = json.loads(ready.read_text())
        status['url'] = 'http://127.0.0.1:' + str(status['port'])
        put('h3-http-ready.json', json.dumps(status).encode())
        deadline = time.monotonic() + args.seconds + 3600
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Box HTTP fixture stopped during the scenario')
            put('h3-http.jsonl', log.read_bytes())
            try:
                request('/file?path=h3-http-stop')
                break
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
            time.sleep(2)
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if log.exists():
            put('h3-http.jsonl', log.read_bytes())
        put('h3-http-stopped.json', json.dumps(dict(stopped=True)).encode())


if __name__ == '__main__':
    main()
