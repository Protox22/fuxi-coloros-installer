#!/usr/bin/env python3
"""Read-only full payload audit: hashes, image bounds, zstd/sparse/LP and host VerifyOnly."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'installer/scripts'))
import payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    version = (ROOT / 'VERSION').read_text(encoding='ascii').strip()
    parser.add_argument('--output', type=Path, default=ROOT / ('releases/verification-' + version + '.json'))
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    root = ROOT / 'installer'
    profile = payload.read_profile(root / 'firmware.conf')
    records = []
    # VerifyOnly is the only host entry mode used by this tool.
    commands = []
    if os.name == 'nt':
        ps = Path(os.environ['WINDIR']) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
        commands.append(('windows', [str(ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / 'flash.ps1'), '-VerifyOnly', '-Language', 'en']))
    bash = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
    commands.append(('bash', [bash, str(root / 'flash.sh'), '--verify-only', '--language', 'en']))
    for host, command in commands:
        print('Full VerifyOnly: ' + host, flush=True)
        start = time.monotonic()
        result = subprocess.run(command, capture_output=True, timeout=900)
        log = args.output.with_name(args.output.stem + '-' + host + '.log')
        log.write_bytes(result.stdout + result.stderr)
        if result.returncode: raise RuntimeError('VerifyOnly failed: ' + str(log))
        records.append(dict(host=host, mode='VerifyOnly', seconds=round(time.monotonic()-start, 2), passed=True))
    print('Validate real image headers and bounds...', flush=True)
    for name in ('recovery', 'boot', 'init_boot', 'vendor_boot', 'dtbo', 'vbmeta', 'vbmeta_system'):
        payload.validate_image(root / ('images/' + name + '.img'), 'vbmeta' if name.startswith('vbmeta') else 'boot' if name == 'recovery' else name)
    payload.validate_image(root / 'tools/TWRP-FUXI-A17.img', 'boot')
    print('Stream and validate entire real zstd/sparse/LP payload...', flush=True)
    size, digest = payload.inspect_zstd(root)
    if str(size) != profile['super_sparse_bytes'] or digest != profile['super_sha256']:
        raise RuntimeError('Decompressed sparse does not match the pinned profile')
    report = dict(hosts=records, image_headers=True, zstd_sparse_lp=True, sparse_bytes=size, sparse_sha256=digest,
                  real_device=False, manifest_sha256=payload.digest(root/'SHA256SUMS.txt'))
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print('PASS: ' + str(args.output), flush=True)


if __name__ == '__main__': main()
