"""Offline sparse/LP parser and editable-payload workflow regression tests."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import unittest

BASE = Path(__file__).resolve().parent
SOURCE = BASE.parent / 'installer'
import uuid
WORK = BASE / '.work' / ('payload-' + uuid.uuid4().hex[:8])
WORK.mkdir(parents=True)
sys.dont_write_bytecode = True
sys.path.insert(0, str(SOURCE / 'scripts'))
import payload

from synthetic_payload import lp_prefix
PREFIX = lp_prefix()
ZSTD = str(SOURCE / 'bin/platform-tools-windows/zstd.exe') if os.name == 'nt' else shutil.which('zstd')
BLOCKS = payload.SUPER_BYTES // 4096
SPARSE = (struct.pack('<I4H4I', 0xed26ff3a, 1, 0, 28, 12, 4096, BLOCKS, 2, 0)
          + struct.pack('<2H2I', 0xcac1, 0, len(PREFIX) // 4096, len(PREFIX) + 12) + PREFIX
          + struct.pack('<2H2I', 0xcac3, 0, BLOCKS - len(PREFIX) // 4096, 12))


def image_bytes(kind):
    data = bytearray(8192)
    if kind == 'vbmeta':
        data[:4] = b'AVB0'
        struct.pack_into('>I', data, 4, 1)
        struct.pack_into('>Q', data, 20, 64)
    elif kind == 'dtbo':
        struct.pack_into('>8I', data, 0, 0xd7b7ab1e, 8192, 32, 32, 1, 32, 4096, 0)
        struct.pack_into('>2I', data, 32, 4, 4096)
    elif kind == 'vendor_boot':
        data[:8] = b'VNDRBOOT'
        struct.pack_into('<2I', data, 8, 3, 4096)
        struct.pack_into('<I', data, 24, 4)
        struct.pack_into('<I', data, 2096, 2112)
    else:
        data[:8] = b'ANDROID!'
        struct.pack_into('<I', data, 12, 4)
        struct.pack_into('<I', data, 20, 1584)
        struct.pack_into('<I', data, 40, 4)
    return bytes(data)


def fixture(name):
    root = WORK / name
    root.mkdir(exist_ok=True)
    for relative in payload.REQUIRED:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if relative == 'firmware.conf' or relative.endswith(('.py', '.ps1', '.sh', '.bat')):
            shutil.copy2(SOURCE / relative, target)
        elif relative.endswith('zstd.exe') and os.name == 'nt' and (SOURCE / relative).exists():
            shutil.copy2(SOURCE / relative, target)
        elif relative.endswith('.img'):
            target.write_bytes(image_bytes('vbmeta' if 'vbmeta' in relative else 'boot'))
        else:
            target.write_bytes(b'Synthetic test file')
    for name in payload.EXTRAS:
        (root / 'images' / (name + '.img')).write_bytes(image_bytes(name))
    shutil.copy2(SOURCE / 'SHA256SUMS.txt', root / 'SHA256SUMS.txt')
    return root


class PayloadTests(unittest.TestCase):
    def test_valid_lp(self):
        payload.validate_lp(PREFIX)

    def test_image_bounds(self):
        for kind in ('boot', 'init_boot', 'vendor_boot', 'dtbo', 'vbmeta'):
            path = WORK / (kind + '.img')
            original = image_bytes(kind)
            path.write_bytes(original)
            payload.validate_image(path, kind)
            for length in (4, 8, 64, 256, 4097 if kind != 'vbmeta' else 128):
                with self.subTest(kind=kind, length=length):
                    path.write_bytes(original[:length])
                    with self.assertRaises(ValueError):
                        payload.validate_image(path, kind)
        path = WORK / 'vbmeta.img'
        bad = bytearray(image_bytes('vbmeta'))
        struct.pack_into('>Q', bad, 12, 8192)
        path.write_bytes(bad)
        with self.assertRaises(ValueError):
            payload.validate_image(path, 'vbmeta')
        for relative in ('images/recovery.img', 'tools/TWRP-FUXI-A17.img', 'images/vbmeta.img', 'images/vbmeta_system.img'):
            if (SOURCE / relative).exists():
                payload.validate_image(SOURCE / relative, 'vbmeta' if 'vbmeta' in relative else 'boot')

    def test_truncated_lp(self):
        for length in (0, 52, 4096, 8192, 12288, 12288 + 65536 * 6 - 1):
            with self.subTest(length=length), self.assertRaises(ValueError):
                payload.validate_lp(PREFIX[:length])

    def test_vendor_ramdisk_table_bounds(self):
        path = WORK / 'vendor-v4.img'
        data = bytearray(12288)
        data[:8] = b'VNDRBOOT'
        struct.pack_into('<2I', data, 8, 4, 4096)
        struct.pack_into('<I', data, 24, 4096)
        struct.pack_into('<I', data, 2096, 2128)
        struct.pack_into('<4I', data, 2112, 108, 1, 108, 0)
        struct.pack_into('<3I', data, 8192, 4096, 0, 1)
        path.write_bytes(data)
        payload.validate_image(path, 'vendor_boot')
        struct.pack_into('<I', data, 8196, 4096)
        path.write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'entry exceeds'):
            payload.validate_image(path, 'vendor_boot')

    def test_lp_checksums_and_copies(self):
        for offset in (4096, 8192, 12288, 12288 + 65536 * 5):
            with self.subTest(offset=offset):
                bad = bytearray(PREFIX)
                bad[offset] ^= 1
                with self.assertRaises(ValueError):
                    payload.validate_lp(bad)

    def test_reject_sparse_corruption(self):
        mutations = (bytes(28), SPARSE[:27], SPARSE[:100], SPARSE[:28] + bytes(12),
                     SPARSE[:16] + struct.pack('<I', BLOCKS - 1) + SPARSE[20:])
        for data in mutations:
            with self.subTest(size=len(data)):
                with self.assertRaises(ValueError):
                    payload.inspect_sparse(io.BytesIO(data))

    def test_valid_sparse_stream(self):
        size, value = payload.inspect_sparse(io.BytesIO(SPARSE))
        self.assertEqual((size, value), (len(SPARSE), hashlib.sha256(SPARSE).hexdigest()))

    def test_profile_rejections(self):
        original = payload.read_profile(SOURCE / 'firmware.conf')
        for key, value in (('format', '2'), ('name', '../bad'), ('base_firmware', '$(command)'),
                           ('super_expanded_bytes', str(9 * 1024**3)), ('super_sparse_bytes', '-1'),
                           ('super_sparse_bytes', '0'), ('super_sha256', 'Z' * 64),
                           ('extra_images', 'boot,boot'), ('extra_images', 'modem'), ('extra_images', 'boot,')):
            with self.subTest(key=key, value=value):
                bad = dict(original)
                bad[key] = value
                with self.assertRaises(ValueError):
                    payload.validate_profile(bad)

    def test_existing_lock_is_not_removed(self):
        root = fixture('locked')
        lock = root / '.installer.lock'
        lock.write_text('OTHER OWNER')
        try:
            with self.assertRaises(FileExistsError):
                payload.prepare(root, installer_only=True)
            self.assertEqual(lock.read_text(), 'OTHER OWNER')
        finally:
            lock.unlink()

    def test_template_and_required_super(self):
        root = fixture('template')
        with self.assertRaises(ValueError):
            payload.prepare(root)
        with self.assertRaises(ValueError):
            payload.prepare(root, name='Changed', installer_only=True)
        before = (root / 'SHA256SUMS.txt').read_text()
        original_super = next(x for x in before.splitlines() if x.endswith('./images/super.img.zst'))
        _, count, missing = payload.prepare(root, installer_only=True)
        self.assertTrue(missing)
        self.assertIn(original_super, (root / 'SHA256SUMS.txt').read_text())
        self.assertFalse((root / '.installer.lock').exists())
        self.assertGreaterEqual(count, len(payload.REQUIRED))

    @unittest.skipUnless(ZSTD and Path(ZSTD).is_file(), 'Real zstd is required for compression integration')
    def test_full_changed_payload_and_extras(self):
        root = fixture('updated release & bang!')
        raw = WORK / 'synthetic-super.img'
        raw.write_bytes(SPARSE)
        compressed = root / 'images/super.img.zst'
        subprocess.run([ZSTD, '-q', '-f', str(raw), '-o', str(compressed)], check=True)
        for name in payload.EXTRAS:
            (root / 'images' / (name + '.img')).write_bytes(image_bytes(name))
        (root / 'images' / 'release_notes.txt').write_text('Extra file must be hashed, never auto-flashed')
        profile, count, missing = payload.prepare(root, name='TestROM-v2', base_firmware='OS3.TEST', extra_images=','.join(payload.EXTRAS))
        self.assertFalse(missing)
        self.assertEqual(profile['name'], 'TestROM-v2')
        self.assertEqual(profile['base_firmware'], 'OS3.TEST')
        self.assertEqual(profile['super_sparse_bytes'], str(len(SPARSE)))
        self.assertEqual(profile['super_sha256'], hashlib.sha256(SPARSE).hexdigest())
        self.assertFalse((root / '.installer.lock').exists())
        manifest = (root / 'SHA256SUMS.txt').read_text()
        for line in manifest.splitlines():
            expected, relative = line.split('  ./', 1)
            self.assertEqual(payload.digest(root / relative), expected, relative)
        self.assertIn('images/release_notes.txt', manifest)
        powershell = Path(os.environ.get('WINDIR', '/')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        commands = [[('C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')), str(root / 'flash.sh'), '--verify-only', '--language', 'en']]
        if os.name == 'nt': commands.append([str(powershell), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / 'flash.ps1'), '-VerifyOnly', '-Language', 'en'])
        for command in commands:
            completed = subprocess.run(command, capture_output=True, timeout=60)
            self.assertEqual(completed.returncode, 0, (completed.stdout + completed.stderr).decode(errors='replace'))
            self.assertIn(b'No device commands', completed.stdout)
        saved = ((root / 'firmware.conf').read_bytes(), (root / 'SHA256SUMS.txt').read_bytes())
        (root / 'images/boot.img').write_bytes(b'BAD')
        with self.assertRaises(ValueError):
            payload.prepare(root)
        self.assertEqual(saved, ((root / 'firmware.conf').read_bytes(), (root / 'SHA256SUMS.txt').read_bytes()))
        self.assertFalse((root / '.installer.lock').exists())
        completed = subprocess.run([sys.executable, str(root / 'prepare-payload.py')], capture_output=True, timeout=20)
        self.assertEqual(completed.returncode, 1)
        self.assertIn(b'Invalid Android boot magic', completed.stderr)

    @unittest.skipUnless(os.name == 'nt', 'Windows BAT launcher')
    def test_prepare_launcher_exit_code(self):
        stubs = WORK / 'fake-python'
        stubs.mkdir(exist_ok=True)
        (stubs / 'py.cmd').write_text('@echo off\r\nexit /b 7\r\n')
        env = dict(os.environ)
        env['PATH'] = str(stubs) + os.pathsep + env['PATH']
        result = subprocess.run([os.environ['COMSPEC'], '/d', '/v:on', '/c', 'PREPARE_PAYLOAD.bat'],
                                cwd=SOURCE, env=env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 7)


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(PayloadTests))
    (WORK / 'results.json').write_text(json.dumps(dict(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors), ok=result.wasSuccessful()), indent=2))
    sys.exit(0 if result.wasSuccessful() else 1)
