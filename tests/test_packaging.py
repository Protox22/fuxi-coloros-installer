"""Archive safety and exact content, using tiny synthetic payloads."""
import importlib.util
import json
import sys
import zipfile
from host_support import BASE, WORK, fixture, sums

spec = importlib.util.spec_from_file_location('build_release', BASE.parent / 'tools/build_release.py')
build_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_release)
results = []
for case in ('full', 'installer', 'bare', 'r2187-bare', 'missing-entry', 'duplicate-case', 'traversal', 'double-slash',
             'tampered-source', 'lock', 'private-log', 'private-report', 'existing-archive'):
    directory = WORK / case
    r2187 = case == 'r2187-bare'
    profile = 'r2187' if r2187 else 'pkg110'
    kind = 'bare' if r2187 else case
    root = fixture(directory / 'release', BASE.parent / 'installer-r2187') if r2187 else fixture(directory / 'release')
    out = directory / 'output'; out.mkdir()
    manifest = root / 'SHA256SUMS.txt'
    text = manifest.read_text()
    if case == 'missing-entry': manifest.write_text(''.join(x for x in text.splitlines(True) if not x.endswith('./flash.sh\n')))
    if case == 'duplicate-case': manifest.write_text(text + next(x for x in text.splitlines(True) if x.endswith('./flash.sh\n')).replace('flash.sh', 'FLASH.SH'))
    if case == 'traversal': manifest.write_text(text + '0'*64+'  ./../outside\n')
    if case == 'double-slash': manifest.write_text(text + '0'*64+'  ./images//other\n')
    if case == 'tampered-source': (root / 'images/recovery.img').write_bytes(b'bad')
    if case == 'lock': (root / '.installer.lock').write_text('other owner')
    if case == 'private-log': manifest.write_text(text + '0'*64+'  ./logs/private.log\n')
    if case == 'private-report': manifest.write_text(text + '0'*64+'  ./reports/private.zip\n')
    sentinel = out / 'FUXI-INSTALLER-0.0.0-PKG110-FULL.zip'
    if case == 'existing-archive': sentinel.write_bytes(b'old release')
    try:
        record = build_release.build(kind if kind in ('installer','bare') else 'full', '0.0.0', root, out, profile=profile)
        okay = kind in ('full', 'installer', 'bare')
        with zipfile.ZipFile(out / record['file']) as archive:
            okay &= archive.testzip() is None
            okay &= ('FUXI-INSTALLER/images/super.img.zst' in archive.namelist()) == (case == 'full')
            okay &= archive.getinfo('FUXI-INSTALLER/START.sh').external_attr >> 16 & 0o777 == 0o755
            if kind=='bare':
                okay &= not any(n.startswith(('FUXI-INSTALLER/images/','FUXI-INSTALLER/tools/')) for n in archive.namelist())
                okay &= 'FUXI-INSTALLER/bin/platform-tools-windows/fastboot.exe' in archive.namelist()
            if r2187:
                okay &= 'PKG110-R2187' in record['file']
                okay &= 'images/boot-no-root.img' in record['omitted']
                okay &= {'FUXI-INSTALLER/boot-variants.conf', 'FUXI-INSTALLER/BOOT_VARIANTS.json',
                         'FUXI-INSTALLER/super-resize/RESIZE.bat'} <= set(archive.namelist())
            okay &= all(archive.read(name) == (root / name.removeprefix('FUXI-INSTALLER/')).read_bytes() for name in archive.namelist())
    except (ValueError, FileExistsError):
        okay = kind not in ('full', 'installer', 'bare') and not list(out.glob('*.pending.zip'))
    if case == 'existing-archive': okay &= sentinel.read_bytes() == b'old release'
    result = dict(case=case, ok=bool(okay))
    results.append(result)
    print(json.dumps(result), flush=True)
(WORK / 'results.json').write_text(json.dumps(results, indent=2))
print('Packaging results: ' + str(WORK / 'results.json'))
sys.exit(0 if all(x['ok'] for x in results) else 1)
