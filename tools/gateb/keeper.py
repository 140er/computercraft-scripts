"""Own the suite flock and child processes for one runtime pool."""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time


def call(home, request):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(20)
        sock.connect(str(Path(home) / 'keeper.sock'))
        sock.sendall(json.dumps(request).encode() + b'\n')
        data = b''
        while b'\n' not in data:
            part = sock.recv(65536)
            if not part:
                raise RuntimeError('Keeper disconnected')
            data += part
        response = json.loads(data)
        if not response['ok']:
            raise RuntimeError(response['error'])
        return response['result']


def main(home, suite_lock):
    home = Path(home)
    lock = open(suite_lock, 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        (home / 'keeper-error').write_text('The shared test-suite lock is held by another test run')
        return
    parent_pid=os.getpid()
    def child_guard():
        # Keep the flock until the child exits, even if the keeper crashes.
        if sys.platform.startswith('linux'):
            ctypes.CDLL(None).prctl(1,signal.SIGTERM)
            if os.getppid()!=parent_pid: os._exit(1)

    children = {}
    handles = {}
    sockpath = home / 'keeper.sock'
    sockpath.unlink(missing_ok=True)
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(sockpath));listener.listen();listener.settimeout(.5)
    os.chmod(sockpath, 0o600)
    idle = time.monotonic()
    stopping = False

    def terminate(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        while not stopping:
            for key, process in list(children.items()):
                if process.poll() is not None:
                    children.pop(key)
                    for handle in handles.pop(key):
                        handle.close() if hasattr(handle, 'close') else os.close(handle)
            if children:
                idle = time.monotonic()
            elif time.monotonic() - idle > 8:
                break
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                continue
            with conn:
                conn.settimeout(5)
                try:
                    data = b''
                    while b'\n' not in data:
                        part = conn.recv(65536)
                        if not part or len(data) > 1048576:
                            raise RuntimeError('Invalid keeper request')
                        data += part
                    q = json.loads(data)
                    key = q.get('key')
                    if q['op'] == 'status':
                        result = {k:p.pid for k,p in children.items()}
                    elif q['op'] == 'start':
                        if key in children:
                            result = {'pid':children[key].pid, 'existing':True}
                        else:
                            if q.get('memory_kib', 0):
                                available = int(next(v.split()[1] for v in Path('/proc/meminfo').read_text().splitlines() if v.startswith('MemAvailable:')))
                                if available < q['memory_kib']:
                                    raise RuntimeError('At least 3 GiB available memory is required per new server/client')
                            log = open(q['log'], 'ab', buffering=0)
                            stdin = os.open(q['fifo'], os.O_RDWR) if q.get('fifo') else open(os.devnull, 'rb')
                            try:
                                process = subprocess.Popen(q['argv'], cwd=q['cwd'], env=q.get('env'), stdin=stdin, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(lock.fileno(),), preexec_fn=child_guard)
                            except Exception:
                                log.close()
                                stdin.close() if hasattr(stdin,'close') else os.close(stdin)
                                raise
                            children[key] = process;handles[key] = [log,stdin]
                            result = {'pid':process.pid, 'existing':False}
                    elif q['op'] == 'signal':
                        if key in children:
                            os.killpg(children[key].pid, signal.SIGTERM)
                        result = True
                    else:
                        raise RuntimeError('Unknown keeper operation')
                    response = {'ok':True,'result':result}
                except Exception as exc:
                    response = {'ok':False,'error':str(exc)}
                try:
                    conn.sendall(json.dumps(response).encode() + b'\n')
                except (BrokenPipeError,ConnectionResetError):
                    pass
    finally:
        for process in children.values():
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
        for process in children.values():
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL);process.wait()
        listener.close();sockpath.unlink(missing_ok=True)
        lock.close()


if __name__ == '__main__':
    main(*sys.argv[1:])
