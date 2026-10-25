import concurrent.futures
from contextlib import ExitStack
import json
import os
from pathlib import Path
import socket
import sys
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from world import Runtime, atomic, locked
import keeper
import run as driver
from checks.model import Blocked


class PortTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.runtime = Runtime(temp.name)
        status_patch = patch.object(self.runtime, 'status', return_value={})
        self.status = status_patch.start()
        self.addCleanup(status_patch.stop)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            self.port = sock.getsockname()[1]
        self.runtime.config.update(port_start=self.port, port_end=self.port + 100)
        self.registry = self.runtime.home / 'ports.json'

    def world(self, name, pid=None, pid_start_time=None):
        path = self.runtime.run(name)
        path.mkdir(parents=True, exist_ok=True)
        state = {'version': 1, 'name': name, 'port': self.port}
        if pid is not None:
            state['pid'] = pid
        if pid_start_time is not None:
            state['pid_start_time'] = pid_start_time
        atomic(path / 'run.json', state)
        (path / 'server.properties').write_text(f'server-port={self.port}\n')
        return path

    def test_normal_stop_releases_only_its_entry(self):
        self.world('scratch')
        atomic(self.registry, {'scratch': self.port, 'other': self.port + 1})
        self.assertTrue(self.runtime.stop('scratch')['stopped'])
        self.assertEqual(json.loads(self.registry.read_text()), {'other': self.port + 1})
        self.runtime.stop('scratch')
        self.assertEqual(json.loads(self.registry.read_text()), {'other': self.port + 1})

    def test_stop_releases_on_exception_after_server_exits(self):
        self.world('scratch')
        atomic(self.registry, {'scratch': self.port})
        with patch.object(self.runtime, 'client_stop', side_effect=RuntimeError('cleanup failed')):
            with self.assertRaisesRegex(RuntimeError, 'cleanup failed'):
                self.runtime.stop('scratch')
        self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_stop_exception_keeps_a_live_servers_entry(self):
        self.world('scratch', os.getpid(), keeper.process_start_time(os.getpid()))
        atomic(self.registry, {'scratch': self.port})
        with patch.object(self.runtime, 'client_stop', side_effect=RuntimeError('cleanup failed')):
            with self.assertRaisesRegex(RuntimeError, 'cleanup failed'):
                self.runtime.stop('scratch')
        self.assertEqual(json.loads(self.registry.read_text()), {'scratch': self.port})

    def test_full_registry_reclaims_deleted_runs(self):
        atomic(self.registry, {f'deleted-{i}': self.port + i for i in range(100)})
        port = self.runtime.allocate_port('new')
        self.assertIn(port, range(self.port, self.port + 100))
        self.assertEqual(json.loads(self.registry.read_text()), {'new': port})

    def test_full_registry_reclaims_dead_owner_with_retained_directory(self):
        self.world('crashed', 12345, 100)
        self.runtime.config['port_end'] = self.port + 1
        atomic(self.registry, {'crashed': self.port})
        with patch('keeper.process_start_time', side_effect=FileNotFoundError):
            self.assertEqual(self.runtime.allocate_port('new'), self.port)
        self.assertEqual(json.loads(self.registry.read_text()), {'new': self.port})

    def test_missing_run_with_held_owner_lock_is_retained(self):
        atomic(self.registry, {'live': self.port})
        self.runtime.config['port_end'] = self.port + 1
        with locked(self.runtime.lock_path('live')):
            with self.assertRaisesRegex(RuntimeError, 'No free Gate B ports'):
                self.runtime.allocate_port('new')
        self.assertEqual(json.loads(self.registry.read_text()), {'live': self.port})

    def test_live_pid_with_unlocked_owner_lock_is_retained(self):
        self.world('live', os.getpid(), keeper.process_start_time(os.getpid()))
        atomic(self.registry, {'live': self.port})
        self.runtime.config['port_end'] = self.port + 1
        with self.assertRaisesRegex(RuntimeError, 'No free Gate B ports'):
            self.runtime.allocate_port('new')
        self.assertEqual(json.loads(self.registry.read_text()), {'live': self.port})

    def test_keeper_live_entry_is_retained_even_without_run_directory(self):
        atomic(self.registry, {'live': self.port})
        self.status.return_value = {'live': os.getpid()}
        self.runtime.config['port_end'] = self.port + 1
        with self.assertRaisesRegex(RuntimeError, 'No free Gate B ports'):
            self.runtime.allocate_port('new')
        self.assertEqual(json.loads(self.registry.read_text()), {'live': self.port})

    def test_reused_pid_with_different_start_time_is_reclaimed(self):
        self.world('crashed', os.getpid(), keeper.process_start_time(os.getpid()) + 1)
        atomic(self.registry, {'crashed': self.port})
        self.runtime.config['port_end'] = self.port + 1
        self.assertEqual(self.runtime.allocate_port('new'), self.port)
        self.assertEqual(json.loads(self.registry.read_text()), {'new': self.port})

    def test_legacy_unrelated_live_pid_is_reclaimed(self):
        self.world('crashed', os.getpid())
        atomic(self.registry, {'crashed': self.port})
        self.runtime.config['port_end'] = self.port + 1
        self.assertEqual(self.runtime.allocate_port('new'), self.port)
        self.assertEqual(json.loads(self.registry.read_text()), {'new': self.port})

    def test_cleanup_releases_reservation_with_reused_pid(self):
        for start_time in (None, keeper.process_start_time(os.getpid()) + 1):
            with self.subTest(start_time=start_time):
                self.world('crashed', os.getpid(), start_time)
                atomic(self.registry, {'crashed': self.port})
                self.runtime.stop('crashed')
                self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_legacy_owner_is_verified_by_cwd_or_cmdline(self):
        path = self.world('legacy')
        for source in ('cwd', 'cmdline'):
            with self.subTest(source=source):
                argv = [sys.executable, '-c', 'import time; time.sleep(60)']
                if source == 'cmdline':
                    argv.append('@' + str(path / 'libraries/args.txt'))
                child = subprocess.Popen(argv, cwd=path if source == 'cwd' else self.runtime.home)
                try:
                    self.world('legacy', child.pid)
                    atomic(self.registry, {'legacy': self.port})
                    self.runtime.config['port_end'] = self.port + 1
                    with self.assertRaisesRegex(RuntimeError, 'No free Gate B ports'):
                        self.runtime.allocate_port('new')
                    self.assertEqual(json.loads(self.registry.read_text()), {'legacy': self.port})
                finally:
                    child.terminate()
                    child.wait(timeout=5)

    def test_legacy_cmdline_does_not_match_a_neighboring_run(self):
        path = self.world('legacy')
        for argument in (self.runtime.run('legacy-other') / 'args.txt', path / '../legacy-other/args.txt'):
            with self.subTest(argument=str(argument)):
                child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)',
                                          str(argument)], cwd=self.runtime.home)
                try:
                    self.world('legacy', child.pid)
                    atomic(self.registry, {'legacy': self.port})
                    self.runtime.config['port_end'] = self.port + 1
                    self.assertEqual(self.runtime.allocate_port('new'), self.port)
                finally:
                    child.terminate()
                    child.wait(timeout=5)

    def test_start_time_parser_handles_parentheses_in_process_name(self):
        fields = ['S'] + ['0'] * 18 + ['987654'] + ['0'] * 10
        with patch.object(Path, 'read_text', return_value='123 (name with ) spaces) ' + ' '.join(fields)):
            self.assertEqual(keeper.process_start_time(123), 987654)

    def test_clone_exception_releases_allocation_and_removes_scratch(self):
        template = self.runtime.home / 'template'
        atomic(template / 'manifest.json', {'prepared': True})
        (template / 'server.properties').write_text('server-ip=127.0.0.1\n')
        original = atomic

        def fail_state(path, value):
            if Path(path).name == 'run.json':
                raise OSError('state write failed')
            original(path, value)

        with patch.object(self.runtime, 'refresh_farm_manifest'), patch('world.atomic', side_effect=fail_state):
            with self.assertRaisesRegex(OSError, 'state write failed'):
                self.runtime.clone('scratch')
        self.assertFalse(self.runtime.run('scratch').exists())
        self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_template_cleanup_releases_even_when_disk_preparation_fails(self):
        template = self.runtime.home / 'template'
        template.mkdir()
        (template / 'server.properties').write_text('server-ip=127.0.0.1\n')
        with patch('fixtures.clean_disks', side_effect=RuntimeError('disk failed')):
            with self.assertRaisesRegex(RuntimeError, 'disk failed'):
                self.runtime.prepare_template()
        self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_startup_exception_releases_reserved_port(self):
        self.world('scratch')
        atomic(self.registry, {'scratch': self.port})
        with patch.object(self.runtime, 'ensure_keeper'), patch.object(self.runtime, 'manifest', return_value={'computers': {}}):
            with self.assertRaisesRegex(RuntimeError, 'Expected one NeoForge'):
                self.runtime.serve('scratch')
        self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_reset_exception_releases_before_deleting_world(self):
        path = self.world('scratch')
        (path / 'world').mkdir()
        atomic(self.registry, {'scratch': self.port})
        with patch('world.copytree', side_effect=OSError('copy failed')):
            with self.assertRaisesRegex(OSError, 'copy failed'):
                self.runtime.reset('scratch')
        self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_restart_reserves_again_and_updates_saved_port(self):
        path = self.world('scratch')
        self.runtime.stop('scratch')
        self.runtime.config['port_start'] = self.port + 1
        with locked(self.runtime.lock_path('scratch')):
            port = self.runtime.reserve_port('scratch', self.runtime.state('scratch'))
        self.assertNotEqual(port, self.port)
        self.assertEqual(self.runtime.state('scratch')['port'], port)
        self.assertEqual((path / 'server.properties').read_text().count('server-port='), 1)
        self.assertIn(f'server-port={port}\n', (path / 'server.properties').read_text())
        self.assertEqual(json.loads(self.registry.read_text()), {'scratch': port})

    def test_serve_restarts_with_a_new_port_when_old_port_is_reserved(self):
        path = self.world('scratch')
        arguments = path / 'libraries/net/neoforged/neoforge/test/unix_args.txt'
        arguments.parent.mkdir(parents=True)
        arguments.touch()
        atomic(self.registry, {'other': self.port})
        active = {}
        self.status.side_effect = lambda: active.copy()

        def start(home, request):
            self.assertEqual(request['op'], 'start')
            port = self.runtime.state('scratch')['port']
            self.assertNotEqual(port, self.port)
            self.assertIn(f'server-port={port}\n', (path / 'server.properties').read_text())
            active['scratch'] = os.getpid()
            (path / 'console.log').write_text('Done (1.0s)!\n')
            return {'pid': os.getpid(), 'pid_start_time': keeper.process_start_time(os.getpid())}

        with locked(self.runtime.lock_path('other')), patch.object(self.runtime, 'ensure_keeper'), patch.object(self.runtime, 'command'), patch.object(self.runtime, 'manifest', return_value={'computers': {}, 'forceload': []}), patch('world.keeper.call', side_effect=start):
            result = self.runtime.serve('scratch')
        self.assertTrue(result['warm'])
        self.assertEqual(self.runtime.state('scratch')['pid_start_time'], keeper.process_start_time(os.getpid()))
        self.assertEqual(json.loads(self.registry.read_text()), {'other': self.port, 'scratch': result['port']})

    def test_startup_timeout_stops_owned_process_and_releases_port(self):
        path = self.world('scratch')
        arguments = path / 'libraries/net/neoforged/neoforge/test/unix_args.txt'
        arguments.parent.mkdir(parents=True)
        arguments.touch()
        active = {}
        self.status.side_effect = lambda: active.copy()

        def start(home, request):
            active['scratch'] = 12345
            return {'pid': 12345}

        with patch.object(self.runtime, 'ensure_keeper'), patch.object(self.runtime, 'command', side_effect=lambda *args, **kwargs: active.clear()), patch.object(self.runtime, 'manifest', return_value={'computers': {}}), patch('world.keeper.call', side_effect=start):
            with self.assertRaisesRegex(RuntimeError, 'Server startup timed out'):
                self.runtime.serve('scratch', timeout=0)
        self.assertEqual(active, {})
        self.assertEqual(json.loads(self.registry.read_text()), {})

    def test_duplicate_serve_does_not_stop_an_existing_live_server(self):
        self.world('scratch', os.getpid(), keeper.process_start_time(os.getpid()))
        atomic(self.registry, {'scratch': self.port})
        self.status.return_value = {'scratch': os.getpid()}
        with patch.object(self.runtime, 'ensure_keeper'), patch.object(self.runtime, '_stop') as stop:
            with self.assertRaisesRegex(RuntimeError, 'has not reached its ready marker'):
                self.runtime.serve('scratch')
        stop.assert_not_called()
        self.assertEqual(json.loads(self.registry.read_text()), {'scratch': self.port})

    def test_concurrent_allocation_and_release_preserve_other_owners(self):
        names = [f'clone-{i}' for i in range(16)]
        with ExitStack() as locks:
            for name in names:
                locks.enter_context(locked(self.runtime.lock_path(name)))
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                ports = list(pool.map(self.runtime.allocate_port, names))
            self.assertEqual(len(set(ports)), len(names))
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(self.runtime.release_port, names[:8]))
        self.assertEqual(json.loads(self.registry.read_text()), dict(zip(names[8:], ports[8:])))

    def test_forced_driver_shutdown_releases_port(self):
        self.world('scratch')
        atomic(self.registry, {'scratch': self.port})
        active = {'scratch': 12345}
        self.status.side_effect = lambda: active.copy()
        ctx = SimpleNamespace(runtime=self.runtime, record=lambda *args: None)
        ctx.cli = lambda *args: (_ for _ in ()).throw(Blocked('graceful shutdown failed'))
        with patch.object(driver.importlib, 'import_module') as imported:
            imported.return_value.call.side_effect = lambda home, request: active.clear()
            self.assertTrue(driver.stop_owned(ctx, 'scratch')['stopped'])
        self.assertEqual(json.loads(self.registry.read_text()), {})
