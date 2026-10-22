#!/usr/bin/env python3
"""Add repository-owned part staging to the installed cc-test slot scheduler."""
from pathlib import Path
import shutil
import hashlib

path = Path.home() / '.local/bin/cc-test'
source = path.read_text()
backup = path.with_name(path.name + '.bak-parts')
if not backup.exists():
    shutil.copy2(path, backup)
if "parser.add_argument('--part')" in source:
    marker = '# cc-test-parts-sha256: '
    if marker in source:
        body, checksum = source.rsplit(marker, 1)
        valid = hashlib.sha256(body.encode()).hexdigest() == checksum.strip()
    else:
        valid = hashlib.sha256(source.encode()).hexdigest() == '803e35157e5ec2bae9084085f36b8571e4c29df3de5088b7b346a3074c73dec0'
    if not valid:
        raise SystemExit('cc-test adapter was edited; refusing to overwrite it')
    source = backup.read_text()
changes = [
    ("    parser.add_argument('--slot',", "    parser.add_argument('--shards', type=int, default=1)\n    parser.add_argument('--slot',"),
    ("    branch = git('branch', '--show-current').decode().strip() or 'detached'", "    branch = 'part' if (root / 'tests/part-manifest.lua').is_file() else (git('branch', '--show-current').decode().strip() or 'detached')"),
    ("def snapshot(root):\n", """def snapshot(root):
    if (root / 'tests/part-manifest.lua').is_file():
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as output:
            for path in sorted(root.rglob('*')):
                if path.is_file():
                    output.write(path, 'work/' + path.relative_to(root).as_posix())
            output.writestr('baseline/part-placeholder', 'Part tests do not use a baseline.\\n')
        return archive.getvalue()
"""),
    ("    parser.add_argument('--slot',", "    parser.add_argument('--part')\n    parser.add_argument('--lua-only', action='store_true')\n    parser.add_argument('--part-timeout', type=int, default=60)\n    parser.add_argument('--slot',"),
    ("    os.chdir(root)\n", """    part_temporary = None
    if not 1 <= options.part_timeout <= 1200:
        parser.error('--part-timeout must be between 1 and 1200 seconds')
    if options.lua_only and not options.part:
        parser.error('--lua-only requires --part')
    if options.part:
        sys.path.insert(0, str(root / 'tools'))
        from test_parts import prepare
        original_root = root
        try:
            part_temporary, root, _, _ = prepare(root, options.part, timeout=options.part_timeout)
        except ValueError as error:
            parser.error(str(error))
        import atexit
        atexit.register(part_temporary.cleanup)
    if not 1 <= options.shards <= 64:
        parser.error('--shards must be between 1 and 64')
    if options.shards > 1 and options.part:
        parser.error('--shards cannot be combined with --part')
    full_tools = (root / 'tools/test_suite.py').is_file() and (root / 'tests/suite.lua').is_file()
    if options.shards > 1 and not full_tools:
        parser.error('this checkout has no full-suite sharding tools')
    if not options.part and full_tools:
        sys.path.insert(0, str(root / 'tools'))
        from test_suite import prepare_full, dispatch
        if options.shards > 1:
            return dispatch(root, options.shards, scheduler=str(Path(__file__).resolve()),
                            slot=options.slot, args=args)
        full_temporary, root = prepare_full(root)
        import atexit
        atexit.register(full_temporary.cleanup)
    os.chdir(root)
"""),
    ("['timeout', '20m', 'lua5.2'", "['timeout', str(options.part_timeout) + 's' if options.part else '20m', 'lua5.2'"),
    ("                        return process.wait()", """                        began = time.monotonic()
                        code = process.wait()
                        if options.part:
                            print('part: local Lua wall %.3fs (excludes slot queue)' % (time.monotonic() - began), flush=True)
                        return code"""),
    ("    while True:\n        for slot in slots:", "    emulator_done = False\n    while True:\n        for slot in slots:"),
    ("            try:\n                if SLOTS[slot][0] == 'local':", """            try:
                if options.part and not options.lua_only and not emulator_done:
                    emulator = original_root / 'scripts/test-emulator'
                    if not emulator.is_file():
                        parser.error('emulator runner missing; use explicit --lua-only for unit work')
                    print('cc-test: reserving ' + slot + ' for emulator + Lua part', flush=True)
                    emulator_env = dict(os.environ)
                    emulator_env.pop('CC_TEST_EMULATOR_SLOT', None)
                    if SLOTS[slot][0] == 'local':
                        emulator_env['CC_TEST_EMULATOR_SLOT'] = slot
                    result = subprocess.run([sys.executable, str(emulator)], cwd=original_root, env=emulator_env)
                    if result.returncode == 75:
                        continue
                    if result.returncode:
                        return result.returncode
                    emulator_done = True
                if SLOTS[slot][0] == 'local':
"""),
]
for old, new in changes:
    if source.count(old) != 1:
        raise SystemExit('cc-test changed; refusing ambiguous adapter patch: ' + repr(old))
    source = source.replace(old, new, 1)
compile(source, str(path), 'exec')
source += '# cc-test-parts-sha256: ' + hashlib.sha256(source.encode()).hexdigest() + '\n'
path.write_text(source)
print('Installed cc-test --part; backup: ' + str(backup))
