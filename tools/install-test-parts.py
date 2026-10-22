#!/usr/bin/env python3
"""Add repository-owned part staging to the installed cc-test slot scheduler."""
from pathlib import Path
import shutil

path = Path.home() / '.local/bin/cc-test'
source = path.read_text()
if "parser.add_argument('--part')" in source:
    print('cc-test: part adapter already installed')
    raise SystemExit(0)
backup = path.with_name(path.name + '.bak-parts')
if not backup.exists():
    shutil.copy2(path, backup)
changes = [
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
    ("    parser.add_argument('--slot',", "    parser.add_argument('--part')\n    parser.add_argument('--lua-only', action='store_true')\n    parser.add_argument('--slot',"),
    ("    os.chdir(root)\n", """    part_temporary = None
    if options.lua_only and not options.part:
        parser.error('--lua-only requires --part')
    if options.part:
        sys.path.insert(0, str(root / 'tools'))
        from test_parts import prepare
        original_root = root
        part_temporary, root, _, _ = prepare(root, options.part)
        import atexit
        atexit.register(part_temporary.cleanup)
        if not options.lua_only:
            emulator = original_root / 'scripts/test-emulator'
            if not emulator.is_file():
                parser.error('emulator runner missing; explicit --lua-only is available for unit work')
            result = subprocess.run([str(emulator)], cwd=original_root)
            if result.returncode:
                return result.returncode
    os.chdir(root)
"""),
]
for old, new in changes:
    if source.count(old) != 1:
        raise SystemExit('cc-test changed; refusing ambiguous adapter patch: ' + repr(old))
    source = source.replace(old, new, 1)
compile(source, str(path), 'exec')
path.write_text(source)
print('Installed cc-test --part; backup: ' + str(backup))
