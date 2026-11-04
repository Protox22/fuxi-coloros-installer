"""Small synthetic bundles and fake native tools; never uses real USB tools."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid
sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')

BASE = Path(__file__).resolve().parent
SOURCE = BASE.parent / 'installer'
WORK = BASE / '.work' / ('host-' + uuid.uuid4().hex[:8])
TOOLS = WORK / 'tools'
TOOLS.mkdir(parents=True)
BASH = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
PS = Path(os.environ.get('WINDIR', '/')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
HOSTS = ('windows', 'bash') if os.name == 'nt' else ('bash',)
SYNTHETIC = b'Synthetic sparse image for orchestration tests\n'

if os.name == 'nt':
    csc = Path(os.environ['WINDIR']) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    subprocess.run([str(csc), '/nologo', '/out:' + str(TOOLS / 'mock.exe'), str(BASE / 'mock_tool.cs')], check=True, capture_output=True)
for kind in ('fastboot', 'adb', 'zstd'):
    if os.name == 'nt': shutil.copyfile(TOOLS / 'mock.exe', TOOLS / (kind + '.exe'))
    path = TOOLS / kind
    path.write_text('#!/usr/bin/env bash\nexec "' + Path(sys.executable).as_posix() + '" "' + (BASE / 'mock_device.py').as_posix() + '" ' + kind + ' "$@"\n', encoding='utf-8', newline='\n')
    path.chmod(0o755)


def sums(root):
    paths = [p for p in root.rglob('*') if p.is_file() and p.name not in ('SHA256SUMS.txt', '.installer.lock')
             and not {'logs', 'backups'}.intersection(p.relative_to(root).parts)]
    (root / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ./' + p.relative_to(root).as_posix() + '\n' for p in sorted(paths)), encoding='ascii')


def fixture(root):
    root.mkdir(parents=True)
    names = [line.split('  ./')[1] for line in (SOURCE / 'SHA256SUMS.txt').read_text().splitlines()]
    for name in names:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if name.endswith(('.ps1', '.sh', '.bat', '.py', '.txt')) and not name.startswith('bin/'):
            target.write_bytes((SOURCE / name).read_bytes())
        elif name == 'firmware.conf':
            profile = (SOURCE / name).read_text().splitlines()
            profile = [f'super_sparse_bytes={len(SYNTHETIC)}' if x.startswith('super_sparse_bytes=') else
                       'super_sha256=' + hashlib.sha256(SYNTHETIC).hexdigest() if x.startswith('super_sha256=') else x for x in profile]
            target.write_text('\n'.join(profile) + '\n', encoding='ascii')
        elif name.startswith('bin/') and target.name in ('adb.exe', 'fastboot.exe', 'zstd.exe') and os.name == 'nt':
            shutil.copyfile(TOOLS / target.name, target)
        else:
            target.write_bytes(b'Synthetic payload: ' + name.encode())
    sums(root)
    return root


def environment(directory, case='valid', **state):
    state_file = directory / 'state.json'
    calls_file = directory / 'calls.jsonl'
    state_file.write_text(json.dumps(dict(case=case, **state)))
    calls_file.write_text('')
    env = dict(os.environ, FUXI_TEST_STATE=str(state_file), FUXI_TEST_LOG=str(calls_file),
               FUXI_TEST_PYTHON=sys.executable, FUXI_TEST_MOCK=str(BASE / 'mock_device.py'),
               FASTBOOT=(TOOLS / 'fastboot').as_posix(), ADB=(TOOLS / 'adb').as_posix(), ZSTD=(TOOLS / 'zstd').as_posix(),
               LANGUAGE='en', PYTHONIOENCODING='utf-8')
    # Each synthetic device is isolated by default. Concurrency/retry tests
    # explicitly share this user state across different release directories.
    user_state = directory / 'user-state'
    user_state.mkdir(exist_ok=True)
    env['XDG_STATE_HOME'] = str(user_state)
    env['LOCALAPPDATA'] = str(user_state)
    if os.name == 'nt':
        env['PSMODULEPATH'] = str(PS.parent / 'Modules')
    return env, calls_file


def command(host, root, entry='flash', options=()):
    if host == 'windows':
        return [str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / (entry + '.ps1')), *options]
    return [BASH, str(root / (entry + '.sh')), *options]


def execute(host, root, directory, *, case='valid', entry='flash', options=(), answers='y\ny\n', **state):
    env, calls_file = environment(directory, case, **state)
    completed = subprocess.run(command(host, root, entry, options), input=answers.encode(), capture_output=True,
                               env=env, cwd=directory, timeout=65)
    output = (completed.stdout + completed.stderr).decode('utf-8', errors='replace')
    (directory / 'output.txt').write_text(output, encoding='utf-8')
    calls = [json.loads(x) for x in calls_file.read_text().splitlines()]
    return completed.returncode, output, calls


def native(calls, tool='fastboot'):
    return [c[3:] if c[1:2] == ['-s'] else c[1:] for c in calls if c[0] == tool]
