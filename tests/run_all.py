#!/usr/bin/env python3
"""Reproducible offline suite. No real adb/fastboot calls, USB or block devices."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / 'tests/.work' / time.strftime('suite-%Y%m%d-%H%M%S')
OUTPUT.mkdir(parents=True)
sys.stdout.reconfigure(encoding='utf-8')
env = dict(os.environ, PYTHONIOENCODING='utf-8')
records = []


def run(name, command, timeout=1800):
    start = time.monotonic()
    print('Running ' + name, flush=True)
    with (OUTPUT / (name + '.log')).open('wb') as log:
        try:
            process = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            code = process.returncode
        except subprocess.TimeoutExpired:
            code = 124
    record = dict(group=name, exit=code, passed=code == 0, seconds=round(time.monotonic() - start, 2))
    records.append(record)
    print(json.dumps(record), flush=True)


run('translations', [sys.executable, 'tools/generate_messages.py', '--check'])
bash = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
for path in (ROOT / 'installer').rglob('*.sh'):
    run('syntax-' + path.stem, [bash, '-n', str(path)], 30)
for name in ('hosts', 'integrity', 'ui', 'readiness', 'session_safety', 'payload', 'packaging', 'platform', 'recovery_legacy', 'recovery_gpt31'):
    run(name, [sys.executable, 'tests/test_' + name + '.py'])
sources = {}
for directory in ('installer', 'tests', 'tools'):
    for path in (ROOT / directory).rglob('*'):
        if any(part in ('.work', 'logs', 'backups', '__pycache__') for part in path.parts): continue
        if path.is_file() and path.suffix in ('.sh', '.ps1', '.py', '.cs', '.json'):
            sources[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
report = dict(platform=platform.platform(), python=sys.version, real_device=False, groups=records, sources=sources,
              passed=all(x['passed'] for x in records))
(OUTPUT / 'summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print('Report: ' + str(OUTPUT / 'summary.json'), flush=True)
sys.exit(0 if report['passed'] else 1)
