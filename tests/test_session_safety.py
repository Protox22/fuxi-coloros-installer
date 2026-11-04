"""Cross-copy device exclusion, interrupted restore and cleanup fault injection.

Only synthetic native tools and tiny images; never contacts USB or real disks.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from host_support import BASH, HOSTS, PS, WORK, command, environment, fixture

RESULTS = []
KEY = hashlib.sha256(b'TEST-SERIAL').hexdigest()


def record(name, okay, detail=''):
    RESULTS.append(dict(case=name, ok=bool(okay)))
    print(json.dumps(RESULTS[-1]), flush=True)
    if not okay:
        print(detail, flush=True)


def state_directory(env):
    return Path(env['LOCALAPPDATA' if os.name == 'nt' else 'XDG_STATE_HOME']) / 'FuxiInstaller/devices'


def mutations(calls):
    return [c for c in calls if any(x in c for x in ('flash', 'erase', 'set_active', 'reboot'))
            or 'FUXI_CONFIRM=' in ' '.join(c)]


def restore_command(host, root):
    return command(host, root, 'restore-super', options=['-Language', 'en'] if host == 'windows' else [])


def concurrency(owner_host, contender_host, adb_mode):
    name = f'lock-{owner_host}-{contender_host}-adb-{adb_mode}'
    directory = WORK / name
    first = fixture(directory / 'first/release')
    second = fixture(directory / 'second/release')
    env, _ = environment(first.parent)
    rival_env, rival_log = environment(second.parent, adb_mode=adb_mode)
    for key in ('LOCALAPPDATA', 'XDG_STATE_HOME'):
        rival_env[key] = env[key]
    lock = state_directory(env) / (KEY + '.lock')
    options = ['-Clean'] if owner_host == 'windows' else ['--clean']
    owner = subprocess.Popen(command(owner_host, first, options=options), env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 25
        while not lock.exists() and owner.poll() is None and time.monotonic() < deadline:
            time.sleep(.03)
        acquired = lock.exists()
        options = ['-Clean'] if contender_host == 'windows' else ['--clean']
        rival = subprocess.run(command(contender_host, second, options=options), env=rival_env,
                               input=b'y\ny\n', capture_output=True, timeout=40)
        calls = [json.loads(line) for line in rival_log.read_text().splitlines()]
        reserved = lock.exists()
    finally:
        try:
            out, err = owner.communicate(b'n\n', timeout=40)
        except subprocess.TimeoutExpired:
            owner.kill()
            out, err = owner.communicate()
    (directory / 'owner-output.txt').write_bytes(out + err)
    (directory / 'contender-output.txt').write_bytes(rival.stdout + rival.stderr)
    record(name, acquired and reserved and rival.returncode == 1 and not mutations(calls)
           and owner.returncode == 2 and not lock.exists()
           and not (first / '.installer.lock').exists() and not (second / '.installer.lock').exists(),
           (out + err + rival.stdout + rival.stderr).decode(errors='replace'))


def restore_retry(producer, consumer, failure='erase-failed'):
    name = f'restore-{producer}-{consumer}-{failure}'
    directory = WORK / name
    first = fixture(directory / 'first/release')
    second = fixture(directory / 'second/release')
    env, log = environment(directory, failure)
    failed = subprocess.run(restore_command(producer, first), env=env,
                            input=b'y\ny\n', capture_output=True, timeout=65)
    marker = state_directory(env) / (KEY + '.restore-state')
    expected_stage = {'erase-failed': 'erase.metadata', 'userdata-erase-failed': 'erase.userdata',
                      'restored-recovery-failed': 'flash.recovery_a'}[failure]
    pending = marker.read_text() if marker.exists() else ''
    device_file = Path(env['FUXI_TEST_STATE'])
    state = json.loads(device_file.read_text())
    stock = state.get('size') == '0x240000000'
    state['case'] = 'valid'
    device_file.write_text(json.dumps(state))
    log.write_text('')
    retry = subprocess.run(restore_command(consumer, second), env=env,
                           input=b'y\ny\n', capture_output=True, timeout=65)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    output = (retry.stdout + retry.stderr).decode('utf-8', errors='replace')
    (directory / 'first-output.txt').write_bytes(failed.stdout + failed.stderr)
    (directory / 'retry-output.txt').write_bytes(retry.stdout + retry.stderr)
    record(name, failed.returncode == retry.returncode == 1 and stock
           and pending == expected_stage + '\n' and marker.read_text() == pending
           and 'Unfinished restore' in output and expected_stage in output and not mutations(calls)
           and not list(state_directory(env).glob('*.lock')), output)

    # The marker is bound to the exact serial, not to the copied installer.
    state['serial'] = 'OTHER-SERIAL'
    device_file.write_text(json.dumps(state))
    log.write_text('')
    other = subprocess.run(restore_command(consumer, second), env=env,
                           input=b'', capture_output=True, timeout=40)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    record(name + '-other-device', other.returncode == 0 and not mutations(calls) and marker.exists(),
           (other.stdout + other.stderr).decode(errors='replace'))


def restore_success(host):
    directory = WORK / ('restore-success-' + host)
    root = fixture(directory / 'release')
    env, _ = environment(directory)
    success = subprocess.run(restore_command(host, root), env=env,
                             input=b'y\ny\n', capture_output=True, timeout=65)
    record('restore-success-' + host, success.returncode == 0
           and not list(state_directory(env).glob('*.restore-state'))
           and not list(state_directory(env).glob('*.lock')),
           (success.stdout + success.stderr).decode(errors='replace'))


def invalid_state(host, corrupt):
    name = f'invalid-state-{host}-{corrupt}'
    directory = WORK / name
    root = fixture(directory / 'release')
    env, log = environment(directory, size='0x240000000' if corrupt else '0x2c0000000')
    marker = state_directory(env) / (KEY + '.restore-state')
    marker.parent.mkdir(parents=True)
    if corrupt:
        marker.write_text('not-a-valid-stage\n')
    else:
        marker.mkdir()  # State persistence must fail before recovery/GPT writes.
    result = subprocess.run(restore_command(host, root), env=env,
                            input=b'y\ny\n', capture_output=True, timeout=40)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    record(name, result.returncode == 1 and not mutations(calls)
           and not list(marker.parent.glob('*.lock'))
           and (not corrupt or 'Unfinished restore' in output), output)


def cleanup(host, outcome):
    name = f'cleanup-{host}-{outcome}'
    directory = WORK / name
    root = fixture(directory / 'release')
    env, _ = environment(directory)
    temp = directory / 'temporary'
    temp.mkdir()
    image = temp / 'super.img'
    image.write_bytes(b'Synthetic image')
    temp_failure = outcome == 'temp-failure'
    expected = 1 if outcome == 'error' else 37 if temp_failure else int(outcome)
    if host == 'bash':
        if temp_failure:
            # Git Bash permissions do not model NTFS deletion reliably.
            fault = ('rm() { if [[ " $* " == *" $SUPER_IMAGE "* ]]; then return 1; fi; command rm "$@"; }'
                     if os.name == 'nt' else 'chmod a-w "$(dirname "$SUPER_IMAGE")"')
        else:
            fault = ('record_event() { printf "journal-I/O-error\\n" >&2; return 1; }'
                     if os.name == 'nt' else 'chmod a-w "$EVENT_FILE"')
        ending = 'fail original-error' if outcome == 'error' else 'exit ' + str(expected)
        script = ('source "$1/scripts/common.sh"\nstart_session flash\n'
                  'SERIAL=TEST-SERIAL\nacquire_device_lock\nSUPER_IMAGE="$2"\n'
                  + fault + '\n' + ending + '\n')
        cmd = [BASH, '-c', script, 'test', str(root), str(image)]
    else:
        script = directory / 'probe.ps1'
        # A sharing violation exercises real AppendAllText errors even on NTFS.
        script.write_text('''param([string]$Root,[string]$Image,[string]$Outcome)
$Language='en'
. (Join-Path $Root 'scripts/common.ps1')
$blocker=$null
try {
    Start-Session 'flash'
    $script:Serial='TEST-SERIAL'
    Acquire-DeviceLock
    $script:SuperImage=$Image
    if ($Outcome -eq 'temp-failure') {
        $blocker=[IO.File]::Open($Image,'Open','Read','Read')
        exit 37
    }
    $blocker=[IO.File]::Open($script:EventFile,'Open','Read','None')
    if ($Outcome -eq 'error') { throw 'original-error' }
    exit ([int]$Outcome)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    Show-ErrorHint $_.Exception.Message
    exit 1
} finally {
    try { Stop-Session } finally { if ($null -ne $blocker) { $blocker.Dispose() } }
}
''', encoding='utf-8-sig')
        cmd = [str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script),
               str(root), str(image), outcome]
    result = subprocess.run(cmd, env=env, input=b'', capture_output=True, timeout=20)
    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    (directory / 'output.txt').write_text(output, encoding='utf-8')
    record(name, result.returncode == expected and image.exists() == temp_failure and temp.exists() == temp_failure
           and not (root / '.installer.lock').exists() and not list(state_directory(env).glob('*.lock'))
           and (outcome != 'error' or 'original-error' in output)
           and (not temp_failure or 'Temporary image cleanup failed' in output), output)
    if temp_failure:
        temp.chmod(0o700)
        image.unlink()
        temp.rmdir()


for owner in HOSTS:
    for contender in HOSTS:
        for adb_mode in (False, True):
            concurrency(owner, contender, adb_mode)
        restore_retry(owner, contender)
    for failure in ('userdata-erase-failed', 'restored-recovery-failed'):
        restore_retry(owner, owner, failure)
    restore_success(owner)
    for corrupt in (False, True):
        invalid_state(owner, corrupt)
    for outcome in ('0', '37', 'error', 'temp-failure'):
        cleanup(owner, outcome)

(WORK / 'results.json').write_text(json.dumps(RESULTS, indent=2))
print('Session safety results: ' + str(WORK / 'results.json'), flush=True)
sys.exit(0 if all(x['ok'] for x in RESULTS) else 1)
