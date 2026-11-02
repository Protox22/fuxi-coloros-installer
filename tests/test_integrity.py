"""Bad packages/profiles/CLI flags fail without discovering or writing devices."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import sys
from host_support import HOSTS, WORK, execute, fixture, sums

CASES = ('valid', 'empty', 'missing-entry', 'duplicate', 'bad-hash', 'traversal', 'absolute',
         'double-slash', 'trailing-slash', 'tampered-helper', 'tampered-image', 'missing-dll',
         'missing-super', 'partial-ok', 'partial-bad-super', 'partial-without-entry',
         'lock', 'bad-geometry', 'zero-size', 'negative-size', 'large-size', 'invalid-hash', 'duplicate-key',
         'missing-key', 'unknown-key', 'malicious-name', 'duplicate-extra', 'unknown-extra', 'trailing-comma',
         'uppercase-key', 'missing-extra', 'extra-without-entry', 'conflicting-modes', 'installer-only-invalid', 'unknown-option')


def run(host, entry, case):
    directory = WORK / (host + '-' + entry + '-' + case)
    root = fixture(directory / 'release & spaces Кириллица')
    manifest = root / 'SHA256SUMS.txt'
    original = manifest.read_text()
    options = ['-VerifyOnly'] if host == 'windows' else ['--verify-only']
    expected = 0 if case in ('valid', 'partial-ok') else 1
    if case == 'empty': manifest.write_text('')
    if case == 'missing-entry': manifest.write_text(''.join(x for x in original.splitlines(True) if not x.endswith('./scripts/prepare-super.sh\n')))
    if case == 'duplicate': manifest.write_text(original + original.splitlines(True)[0])
    paths = {'bad-hash': 'NOT_A_HASH  ./flash.sh', 'traversal': '0'*64+'  ./../outside.txt',
             'absolute': '0'*64+'  /etc/passwd', 'double-slash': '0'*64+'  ./images//recovery.img',
             'trailing-slash': '0'*64+'  ./images/recovery.img/'}
    if case in paths: manifest.write_text(paths[case] + '\n')
    if case == 'tampered-helper':
        path = root / 'scripts/common.sh'
        path.write_bytes(path.read_bytes() + b'\n# modified\n')
    if case == 'tampered-image': (root / 'images/recovery.img').write_bytes(b'bad')
    if case == 'missing-dll': (root / 'bin/platform-tools-windows/AdbWinApi.dll').unlink()
    if case in ('missing-super', 'partial-ok', 'partial-without-entry'): (root / 'images/super.img.zst').unlink()
    if case.startswith('partial-'):
        options += ['-InstallerOnly'] if host == 'windows' else ['--installer-only']
    if case == 'partial-bad-super': (root / 'images/super.img.zst').write_bytes(b'bad')
    if case == 'partial-without-entry': manifest.write_text(''.join(x for x in original.splitlines(True) if not x.endswith('./images/super.img.zst\n')))
    if case == 'lock': (root / '.installer.lock').write_text('other-owner')
    mutations = {'bad-geometry': ('super_expanded_bytes', '9663676416'), 'zero-size': ('super_sparse_bytes', '0'),
                 'negative-size': ('super_sparse_bytes', '-1'), 'large-size': ('super_sparse_bytes', '12884901889'),
                 'invalid-hash': ('super_sha256', 'Z'*64), 'malicious-name': ('name', '$(touch_bad)'),
                 'duplicate-extra': ('extra_images', 'boot,boot'), 'unknown-extra': ('extra_images', 'modem'),
                 'trailing-comma': ('extra_images', 'boot,')}
    profile = root / 'firmware.conf'
    text = profile.read_text()
    if case in mutations:
        key, value = mutations[case]
        text = ''.join((key + '=' + value + '\n') if x.startswith(key+'=') else x for x in text.splitlines(True))
    if case == 'duplicate-key': text += 'format=1\n'
    if case == 'missing-key': text = ''.join(x for x in text.splitlines(True) if not x.startswith('name='))
    if case == 'unknown-key': text += 'unknown=1\n'
    if case == 'uppercase-key': text = text.replace('format=', 'Format=')
    if text != profile.read_text():
        profile.write_text(text)
        sums(root)
    if case == 'missing-extra': (root / 'images/boot.img').unlink()
    if case == 'extra-without-entry': manifest.write_text(''.join(x for x in original.splitlines(True) if not x.endswith('./images/boot.img\n')))
    if case == 'conflicting-modes': options += ['-Update'] if host == 'windows' else ['--update']
    if case == 'installer-only-invalid': options = ['-InstallerOnly'] if host == 'windows' else ['--installer-only']
    if case == 'unknown-option': options += ['-Invalid'] if host == 'windows' else ['--invalid']
    rc, output, calls = execute(host, root, directory, entry=entry, options=options, answers='')
    lock = root / '.installer.lock'
    okay = rc == expected and not calls and (lock.read_text() == 'other-owner' if case == 'lock' else not lock.exists())
    if case == 'partial-ok': okay &= ('super.img.zst' in output)
    result = dict(host=host, entry=entry, case=case, exit=rc, ok=okay)
    print(json.dumps(result), flush=True)
    if not okay: print(output[-3000:], flush=True)
    return result


with ThreadPoolExecutor(max_workers=4) as pool:
    futures = [pool.submit(run, host, entry, case) for host in HOSTS for entry in ('flash', 'restore-super') for case in CASES]
    results = [f.result() for f in futures]
(WORK / 'results.json').write_text(json.dumps(results, indent=2))
print('Integrity results: ' + str(WORK / 'results.json'))
sys.exit(0 if all(x['ok'] for x in results) else 1)
