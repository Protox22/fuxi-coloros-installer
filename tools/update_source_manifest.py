#!/usr/bin/env python3
"""Refresh authored text checksums only; never re-pin firmware or vendor binaries."""
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent / 'installer'
NEW = ('scripts/status.ps1', 'scripts/status.sh', 'support-report.ps1', 'support-report.sh', 'START.sh', 'check-base.sh', 'scripts/menu.sh', 'scripts/language.sh',
       'scripts/process.ps1', 'QUICK_START.txt')


def main():
    if (ROOT / '.installer.lock').exists():
        raise SystemExit('Close the installer first.')
    manifest = ROOT / 'SHA256SUMS.txt'
    entries = {}
    for line in manifest.read_text(encoding='ascii').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  \./([A-Za-z0-9_./-]+)', line)
        if not match:
            raise ValueError('Malformed manifest')
        value, name = match.groups()
        if name in entries or any(p in ('', '.', '..') for p in name.split('/')):
            raise ValueError('Unsafe/duplicate manifest path')
        entries[name] = value
    for name in set(entries) | set(NEW):
        # Explicitly excludes firmware.conf, all binary assets and vendor notices.
        editable = (name.endswith(('.ps1', '.sh', '.py', '.bat')) or
                    name in ('README_RU.txt', 'README_PORT_PL.txt', 'BUILDS_RU.txt', 'QUICK_START.txt'))
        if editable:
            entries[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    manifest.write_text(''.join(entries[n] + '  ./' + n + '\n' for n in sorted(entries)), encoding='ascii')


if __name__ == '__main__':
    main()
