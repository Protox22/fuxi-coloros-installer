"""Windows launchers/PowerShell 7 and Bash deadlines, without a real device."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from host_support import BASH, HOSTS, PS, WORK, command, environment, execute, fixture, native, sums

results = []
def record(name, okay):
    results.append(dict(case=name, ok=bool(okay)))
    print(json.dumps(results[-1]), flush=True)

for host in HOSTS:
    directory = WORK / (host + '-manifest-case')
    root = fixture(directory / 'release')
    path = root / 'SHA256SUMS.txt'
    text = path.read_text()
    path.write_text(text + next(x for x in text.splitlines(True) if x.endswith('./flash.sh\n')).replace('flash.sh', 'FLASH.SH'))
    rc, output, calls = execute(host, root, directory, options=['-VerifyOnly'] if host == 'windows' else ['--verify-only'])
    record(host + '-case-alias-refused', rc == 1 and not calls)

directory = WORK / 'bash-timeout'
root = fixture(directory / 'release')
hang = directory / 'hang.sh'
hang.write_text('#!/usr/bin/env bash\ntrap "" TERM\nwhile true; do sleep 1; done\n', newline='\n')
hang.chmod(0o755)
probe = directory / 'probe.sh'
probe.write_text('source "' + (root / 'scripts/common.sh').as_posix() + '"\nFASTBOOT="' + hang.as_posix() + '"\nSERIAL=TEST\nget_fastboot_var product\n', encoding='utf-8', newline='\n')
start = time.monotonic()
result = subprocess.run([BASH, str(probe)], capture_output=True, timeout=35)
record('bash-timeout-kills-ignored-term', result.returncode == 1 and time.monotonic() - start < 30)

if os.name == 'nt':
    pwsh = shutil.which('pwsh')
    for name, engine, args, answers in (
        ('ps7-clean', pwsh, ['-Clean'], 'y\n'),
        ('ps7-update', pwsh, ['-Update'], 'y\n'),
        ('ps7-verify', pwsh, ['-VerifyOnly'], ''),
        ('ps7-menu', pwsh, [], '3\n0\n'),
        ('bat-module-path', 'bat', [], '3\n0\n')):
        if not engine: continue
        directory = WORK / name
        root = fixture(directory / 'release & spaces (test)! Кириллица')
        env, calls_path = environment(directory)
        # Reproduce a PowerShell 7 parent launching Windows PowerShell via BAT.
        if pwsh: env['PSMODULEPATH'] = str(Path(pwsh).parent / 'Modules')
        if engine == 'bat':
            cmd = [os.environ['COMSPEC'], '/d', '/v:on', '/c', 'FLASH.bat']
        else:
            cmd = [engine, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / 'flash.ps1'), *args]
        p = subprocess.run(cmd, cwd=root, env=env, input=answers.encode(), capture_output=True, timeout=90)
        calls = [json.loads(x) for x in calls_path.read_text().splitlines()]
        fb = native(calls)
        okay = p.returncode == 0 and not (root / '.installer.lock').exists()
        if name in ('ps7-verify', 'ps7-menu', 'bat-module-path'): okay &= not calls
        if name == 'ps7-update': okay &= ['reboot'] in fb and not any(x[:1] in (['erase'], ['set_active']) for x in fb)
        if name == 'ps7-clean': okay &= ['reboot'] in fb and ['set_active', 'a'] in fb
        (directory / 'output.txt').write_bytes(p.stdout + p.stderr)
        record(name, okay)

(WORK / 'results.json').write_text(json.dumps(results, indent=2))
print('Platform results: ' + str(WORK / 'results.json'))
sys.exit(0 if all(x['ok'] for x in results) else 1)
