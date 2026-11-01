"""Offline preparation of a fuxi 11 GiB payload. Never invokes adb or fastboot."""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zlib

SUPER_BYTES = 11811160064
KEYS = ('format', 'name', 'base_firmware', 'super_sparse_bytes',
        'super_expanded_bytes', 'super_sha256', 'extra_images')
EXTRAS = ('boot', 'init_boot', 'vendor_boot', 'dtbo')
REQUIRED = (
    'FLASH.bat', 'scripts/menu.ps1', 'scripts/language.ps1', 'check-base.ps1', 'flash.ps1', 'flash.sh',
    'restore-super.ps1', 'restore-super.sh', 'scripts/common.ps1',
    'scripts/common.sh', 'scripts/prepare-super.sh', 'images/recovery.img',
    'images/vbmeta.img', 'images/vbmeta_system.img', 'tools/TWRP-FUXI-A17.img',
    'firmware.conf', 'prepare-payload.py', 'scripts/payload.py', 'PREPARE_PAYLOAD.bat',
    'bin/platform-tools-windows/adb.exe', 'bin/platform-tools-windows/fastboot.exe',
    'bin/platform-tools-windows/zstd.exe', 'bin/platform-tools-windows/AdbWinApi.dll',
    'bin/platform-tools-windows/AdbWinUsbApi.dll', 'bin/platform-tools-windows/NOTICE.txt',
    'bin/platform-tools-windows/source.properties', 'bin/platform-tools-windows/LICENSE-zstd.txt',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_profile(path):
    result = {}
    for line in path.read_text(encoding='ascii').splitlines():
        require(re.fullmatch(r'[a-z][a-z0-9_]*=[A-Za-z0-9._,-]*', line), 'Invalid firmware.conf entry')
        key, value = line.split('=', 1)
        require(key not in result, 'Duplicate firmware.conf key')
        result[key] = value
    validate_profile(result)
    return result


def validate_profile(profile):
    require(set(profile) == set(KEYS), 'Unknown or missing firmware.conf keys')
    require(profile['format'] == '1' and profile['super_expanded_bytes'] == str(SUPER_BYTES),
            'Only the supported fuxi 11 GiB super profile is accepted')
    for key in ('name', 'base_firmware'):
        require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,95}', profile[key]), 'Invalid ' + key)
    size = profile['super_sparse_bytes']
    require(re.fullmatch(r'[1-9][0-9]{1,10}', size) and 28 <= int(size) <= 12884901888,
            'Invalid sparse image size')
    require(re.fullmatch(r'[0-9a-f]{64}', profile['super_sha256']), 'Invalid sparse image SHA-256')
    extra = profile['extra_images'].split(',') if profile['extra_images'] else []
    require(all(x in EXTRAS for x in extra) and len(set(extra)) == len(extra),
            'Unsupported or duplicate extra image')


@contextmanager
def session_lock(root):
    path = root / '.installer.lock'
    with path.open('x', encoding='ascii') as lock:
        try:
            lock.write(f'pid={os.getpid()} operation=prepare\n')
            lock.flush()
            yield
        finally:
            # Close before unlinking on Windows. Only this acquired lock is removed.
            lock.close()
            path.unlink()


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(4 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def validate_image(path, kind):
    """Check declared section bounds, not ROM compatibility or signatures."""
    size = path.stat().st_size
    with path.open('rb') as image:
        header = image.read(4096)

        def number(offset, fmt='<I'):
            require(offset + struct.calcsize(fmt) <= len(header), 'Truncated image header: ' + str(path))
            return struct.unpack_from(fmt, header, offset)[0]

        def aligned(value, page):
            return (value + page - 1) // page * page

        if kind == 'vbmeta':
            require(len(header) >= 256 and header[:4] == b'AVB0', 'Invalid AVB header: ' + str(path))
            require(number(4, '>I') <= 1, 'Unsupported AVB version')
            auth, aux = number(12, '>Q'), number(20, '>Q')
            require(auth % 64 == aux % 64 == 0 and 256 + auth + aux <= size, 'Truncated AVB blocks')
            for offset, limit in ((32, auth), (48, auth), (64, aux), (80, aux), (96, aux)):
                require(number(offset, '>Q') + number(offset + 8, '>Q') <= limit, 'AVB field exceeds its block')
            return
        if kind == 'dtbo':
            require(len(header) >= 32 and header[:4] == b'\xd7\xb7\xab\x1e', 'Invalid DTBO header')
            total, hs, es, count, offset, page, version = struct.unpack_from('>7I', header, 4)
            require(32 <= hs <= total <= size and es >= 32 and count > 0 and offset >= hs
                    and offset + count * es <= total and version == 0 and page > 0,
                    'Invalid DTBO table bounds')
            for i in range(count):
                image.seek(offset + i * es)
                entry = image.read(8)
                require(len(entry) == 8, 'Truncated DTBO entry')
                length, start = struct.unpack('>2I', entry)
                require(length > 0 and start >= offset + count * es and start + length <= total,
                        'DTBO entry exceeds image')
            return
        if kind == 'vendor_boot':
            require(header[:8] == b'VNDRBOOT', 'Invalid vendor boot magic')
            version, page = number(8), number(12)
            require(version in (3, 4), 'Unsupported vendor boot header version')
            hs = 2112 if version == 3 else 2128
            require(number(2096) == hs, 'Invalid vendor boot header size')
            sections = [number(24), number(2100)]
            require(sections[0] > 0, 'Empty vendor ramdisk')
            if version == 4:
                table, count, entry_size, config = (number(x) for x in (2112, 2116, 2120, 2124))
                require(count > 0 and entry_size >= 108 and table == count * entry_size,
                        'Invalid vendor ramdisk table')
                sections += [table, config]
        else:
            require(header[:8] == b'ANDROID!', 'Invalid Android boot magic')
            version = number(40)
            require(version in (0, 1, 2, 3, 4), 'Unsupported Android boot header version')
            if version >= 3:
                hs, page = (1580 if version == 3 else 1584), 4096
                require(number(20) == hs, 'Invalid Android boot header size')
                sections = [number(8), number(12)]
                if version == 4:
                    sections.append(number(1580))
            else:
                hs, page = (1632, 1648, 1660)[version], number(36)
                require(page >= hs and page <= 65536 and page & (page - 1) == 0, 'Invalid boot page size')
                sections = [number(8), number(16), number(24)]
                if version >= 1:
                    require(number(1644) == hs, 'Invalid legacy boot header size')
                    recovery = number(1632)
                    if recovery:
                        require(number(1636, '<Q') == aligned(hs, page) + sum(aligned(x, page) for x in sections),
                                'Invalid recovery DTBO offset')
                    sections.append(recovery)
                if version == 2:
                    sections.append(number(1648))
            require(any(sections[:2]), 'Empty Android boot image')
        require(page >= hs and page <= 65536 and page & (page - 1) == 0, 'Invalid boot page size')
        require(aligned(hs, page) + sum(aligned(x, page) for x in sections) <= size,
                'Truncated boot image sections: ' + str(path))
        if kind == 'vendor_boot' and version == 4:
            table_start = aligned(hs, page) + aligned(sections[0], page) + aligned(sections[1], page)
            for i in range(count):
                image.seek(table_start + i * entry_size)
                entry = image.read(8)
                require(len(entry) == 8, 'Truncated vendor ramdisk table entry')
                length, start = struct.unpack_from('<2I', entry)
                require(length > 0 and start + length <= sections[0], 'Vendor ramdisk entry exceeds ramdisk section')


def validate_lp(raw):
    require(len(raw) >= 12288 + 65536 * 6, 'Truncated LP metadata copies')
    geometry = bytearray(raw[4096:4096 + 52])
    require(len(geometry) == 52, 'Missing LP geometry')
    magic, size = struct.unpack_from('<II', geometry)
    require(magic == 0x616c4467 and size == 52, 'Invalid LP geometry')
    expected = bytes(geometry[8:40])
    geometry[8:40] = bytes(32)
    require(hashlib.sha256(geometry).digest() == expected, 'LP geometry checksum mismatch')
    require(raw[4096:8192] == raw[8192:12288], 'LP geometry copies differ')
    maximum, slots, block = struct.unpack_from('<III', geometry, 40)
    require(maximum == 65536 and slots == 3 and block == 4096,
            'Unsupported LP metadata geometry; retain the reviewed fuxi layout')
    for i in range(slots * 2):
        offset = 12288 + maximum * i
        magic, major, minor, size = struct.unpack_from('<IHHI', raw, offset)
        require(magic == 0x414c5030 and major == 10 and minor <= 2 and 128 <= size <= 256,
                'Unsupported LP metadata header')
        header = bytearray(raw[offset:offset + size])
        expected = bytes(header[12:44])
        header[12:44] = bytes(32)
        require(hashlib.sha256(header).digest() == expected, 'LP header checksum mismatch')
        length = struct.unpack_from('<I', header, 44)[0]
        require(size + length <= maximum, 'LP tables exceed their metadata slot')
        tables = raw[offset + size:offset + size + length]
        require(hashlib.sha256(tables).digest() == header[48:80], 'LP tables checksum mismatch')
        entries = []
        for descriptor, expected_size in zip((80, 92, 104, 116), (52, 24, 48, 64)):
            start, count, entry_size = struct.unpack_from('<III', header, descriptor)
            require(entry_size == expected_size and start + count * entry_size <= len(tables),
                    'Invalid LP table bounds')
            entries.append([tables[start + j * entry_size:start + (j + 1) * entry_size] for j in range(count)])
        parts, extents, groups, devices = entries
        require(len(devices) == 1 and struct.unpack_from('<Q', devices[0], 16)[0] == SUPER_BYTES,
                'LP block device is not an 11 GiB super')
        minimum = struct.unpack_from('<Q', devices[0])[0]
        require(minimum * 512 >= 12288 + slots * maximum * 2, 'LP data overlaps metadata')
        names, ranges = [], []
        used = [0] * len(groups)
        for part in parts:
            name = part[:36].rstrip(b'\0').decode('ascii')
            attrs, first, count, group = struct.unpack_from('<4I', part, 36)
            require(re.fullmatch(r'[a-z0-9_]+_a', name) and name not in names,
                    'Only unique slot A logical partitions are supported')
            require(attrs == 1 and count > 0 and first + count <= len(extents) and group < len(groups),
                    'Unsupported LP partition attributes or extents')
            names.append(name)
            for extent in extents[first:first + count]:
                sectors, kind, target, source = struct.unpack('<QIQI', extent)
                require(kind in (0, 1) and sectors > 0, 'Unsupported LP extent')
                if kind == 0:
                    require(source == 0 and target >= minimum and (target + sectors) * 512 <= SUPER_BYTES,
                            'LP extent exceeds super')
                    ranges.append((target, target + sectors))
                used[group] += sectors * 512
        require({'system_a', 'vendor_a'}.issubset(names), 'Missing system_a or vendor_a')
        ranges.sort()
        require(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])), 'LP extents overlap')
        for group, total in zip(groups, used):
            limit = struct.unpack_from('<Q', group, 40)[0]
            require(limit == 0 or total <= limit, 'LP group exceeds its maximum size')


def inspect_sparse(stream, check_lp=True):
    checksum = hashlib.sha256()
    total = 0
    prefix = bytearray()
    crc = 0

    def take(size):
        nonlocal total
        data = stream.read(size)
        require(len(data) == size, 'Truncated sparse image')
        checksum.update(data)
        total += size
        require(total <= 12884901888, 'Sparse image exceeds supported size')
        return data

    def output(data):
        nonlocal crc
        crc = zlib.crc32(data, crc)
        prefix.extend(data[:max(0, 2 * 1024 * 1024 - len(prefix))])

    header = struct.unpack('<I4H4I', take(28))
    magic, major, minor, fh, ch, block, blocks, chunks, expected_crc = header
    require(magic == 0xed26ff3a and major == 1 and minor == 0 and fh >= 28 and ch >= 12 and block == 4096,
            'Unsupported Android sparse header')
    require(blocks * block == SUPER_BYTES and 0 < chunks <= 1000000, 'Sparse super must expand to exactly 11 GiB')
    take(fh - 28)
    expanded = 0
    for _ in range(chunks):
        kind, reserved, count, length = struct.unpack('<2H2I', take(12))
        take(ch - 12)
        sizes = {0xcac1: count * block, 0xcac2: 4, 0xcac3: 0, 0xcac4: 4}
        require(kind in sizes and length == ch + sizes[kind], 'Invalid sparse chunk length or type')
        require((kind == 0xcac4 and count == 0) or (kind != 0xcac4 and count > 0), 'Invalid sparse chunk block count')
        expanded += count
        require(expanded <= blocks, 'Sparse chunks exceed expanded size')
        remaining = count * block
        if kind == 0xcac4:
            require(struct.unpack('<I', take(4))[0] == crc, 'Sparse CRC chunk mismatch')
        elif kind == 0xcac1:
            while remaining:
                data = take(min(4 * 1024 * 1024, remaining))
                output(data)
                remaining -= len(data)
        else:
            pattern = take(4) if kind == 0xcac2 else bytes(4)
            data = pattern * (1024 * 1024)
            while remaining:
                portion = data[:min(len(data), remaining)]
                output(portion)
                remaining -= len(portion)
    require(expanded == blocks and not stream.read(1), 'Sparse image size mismatch or trailing data')
    require(expected_crc == 0 or expected_crc == crc, 'Sparse header CRC mismatch')
    if check_lp:
        validate_lp(prefix)
    return total, checksum.hexdigest()


def inspect_zstd(root):
    executable = str(root / 'bin/platform-tools-windows/zstd.exe') if os.name == 'nt' else shutil.which('zstd')
    require(executable and Path(executable).is_file(), 'zstd is required to prepare a new super')
    with tempfile.TemporaryFile() as errors:
        with subprocess.Popen([executable, '-q', '-d', '-c', str(root / 'images/super.img.zst')],
                              stdout=subprocess.PIPE, stderr=errors) as process:
            try:
                result = inspect_sparse(process.stdout)
                require(process.wait(timeout=30) == 0, 'zstd decompression/checksum failed')
                return result
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()


def atomic_text(path, text):
    with tempfile.NamedTemporaryFile(mode='w', encoding='ascii', newline='\n',
                                     dir=path.parent, prefix='.payload-', delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(text)
            output.close()
            temporary.replace(path)
        finally:
            if temporary.exists():
                temporary.unlink()


def prepare(root, name=None, base_firmware=None, extra_images=None, installer_only=False):
    root = Path(root).resolve()
    with session_lock(root):
        profile = read_profile(root / 'firmware.conf')
        for key, value in (('name', name), ('base_firmware', base_firmware), ('extra_images', extra_images)):
            if value is not None:
                profile[key] = value
        validate_profile(profile)
        extras = profile['extra_images'].split(',') if profile['extra_images'] else []
        for relative in REQUIRED + tuple('images/' + x + '.img' for x in extras):
            require((root / relative).is_file(), 'Required release file is missing: ' + relative)
        for relative in ('images/recovery.img', 'tools/TWRP-FUXI-A17.img'):
            validate_image(root / relative, 'boot')
        for kind in extras:
            validate_image(root / ('images/' + kind + '.img'), kind)
        for relative in ('images/vbmeta.img', 'images/vbmeta_system.img'):
            validate_image(root / relative, 'vbmeta')
        super_path = root / 'images/super.img.zst'
        missing_hash = None
        if super_path.is_file():
            print('Reading and validating the complete compressed super...', flush=True)
            size, value = inspect_zstd(root)
            profile.update(super_sparse_bytes=str(size), super_sha256=value)
        else:
            require(installer_only, 'Missing images/super.img.zst. Add the ROM or explicitly prepare an installer-only template.')
            entries = [line for line in (root / 'SHA256SUMS.txt').read_text(encoding='ascii').splitlines()
                       if re.fullmatch(r'[0-9a-f]{64}  \./images/super\.img\.zst', line)]
            require(len(entries) == 1, 'Installer-only template requires the existing super checksum')
            require(name is None and base_firmware is None and extra_images is None,
                    'Add the complete super before changing the firmware profile')
            missing_hash = entries[0]
        validate_profile(profile)
        paths = []
        seen = set()
        for path in sorted(root.rglob('*')):
            relative = path.relative_to(root)
            if relative.parts[0] in ('logs', 'backups', '__pycache__') or '__pycache__' in relative.parts or path.name in ('SHA256SUMS.txt', '.installer.lock'):
                continue
            require(not path.is_symlink(), 'Symlinks are not supported: ' + str(relative))
            if not path.is_file():
                continue
            portable = relative.as_posix()
            require(re.fullmatch(r'[A-Za-z0-9_./-]+', portable) and portable.casefold() not in seen,
                    'Unsafe or duplicate portable path: ' + portable)
            seen.add(portable.casefold())
            paths.append((path, portable))
        # The manifest is committed last; interruption leaves a rejected, incomplete update.
        atomic_text(root / 'firmware.conf', ''.join(key + '=' + profile[key] + '\n' for key in KEYS))
        lines = [digest(path) + '  ./' + portable for path, portable in paths]
        if missing_hash:
            lines.append(missing_hash)
        atomic_text(root / 'SHA256SUMS.txt', '\n'.join(sorted(lines, key=lambda x: x[66:])) + '\n')
        return profile, len(lines), bool(missing_hash)
