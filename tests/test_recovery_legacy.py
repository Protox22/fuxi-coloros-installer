"""Mock recovery operations and signed-32-bit numeric test used by Android mksh.

The host remains Bash; its numeric [ comparisons are narrowed to signed 32-bit.
This reproduces the reported preflight failure without a phone or GPT writes.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile
import shutil
import uuid

BASE = Path(__file__).resolve().parent
ROOT = BASE.parent / 'installer'
WORK = BASE / '.work' / ('legacy-' + uuid.uuid4().hex[:8])
WORK.mkdir(parents=True, exist_ok=True)
BASH = 'C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
baseline = os.environ.get('FUXI_GPT_SOURCE_ZIP')
if baseline:
    with zipfile.ZipFile(baseline) as archive:
        script = archive.read('FUXI-INSTALLER/scripts/prepare-super.sh').decode('ascii')
else:
    script = (Path(os.environ.get('FUXI_GPT_SOURCE_DIR', ROOT)) / 'scripts/prepare-super.sh').read_text()
replacements = {'DISK=/dev/block/sda': 'DISK="$FUXI_GPT_DISK"',
    'SGDISK=/system/bin/sgdisk': 'SGDISK="$FUXI_GPT_SGDISK"',
    'BACKUP=/tmp/fuxi-gpt-before.bin': 'BACKUP="$FUXI_GPT_BACKUP"',
    'CURRENT=/tmp/fuxi-gpt-current.bin': 'CURRENT="$FUXI_GPT_CURRENT"',
    '[ -b ': '[ -f ',
    '/dev/block/bootdevice/by-name': '"$FUXI_GPT_BOOT_NAME"',
    '/dev/block/by-name': '"$FUXI_GPT_BY_NAME"',
    '/sys/class/block/sda/queue/logical_block_size': '"$FUXI_GPT_SECTOR"',
    '/proc/mounts': '"$FUXI_GPT_MOUNTS"'}
for old, new in replacements.items():
    if old == '/dev/block/bootdevice/by-name' and old not in script:
        continue  # Historical scripts used only the global by-name directory.
    assert old in script
    script = script.replace(old, new)
(WORK / 'prepare-test.sh').write_text(script, newline='\n')
fake = WORK / 'sgdisk'
fake.write_text(f'#!/usr/bin/env bash\nexport LC_ALL=C.UTF-8\nexec "{Path(sys.executable).as_posix()}" "{(BASE / "mock_gpt.py").as_posix()}" "$@"\n', encoding='utf-8', newline='\n')
fake.chmod(0o755)
runner = WORK / 'run.sh'
runner.write_text('''#!/usr/bin/env bash
set -eu
# Model mksh's signed 32-bit numeric test independently of the script logic.
function [() {
    if [[ $FUXI_GPT_CASE = broken-super-alias && $1 = -f && $2 = */by-name/super ]]; then
        return 1
    fi
    if [[ $# = 4 && $2 =~ ^-(eq|ne|lt|le|gt|ge)$ && $1 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]]; then
        local left right
        left=$(( (10#$1 & 4294967295) ))
        right=$(( (10#$3 & 4294967295) ))
        if (( left >= 2147483648 )); then left=$((left - 4294967296)); fi
        if (( right >= 2147483648 )); then right=$((right - 4294967296)); fi
        builtin [ "$left" "$2" "$right" ]
    else
        builtin [ "$@"
    fi
}
getprop() {
    if [ "$1" = ro.product.device ]; then
        [ "$FUXI_GPT_CASE" != wrong-device ] || { echo other; return; }
        echo fuxi
    else echo TEST-TWRP; fi
}
blockdev() {
    case "$2" in */super|*disk32) echo 11811160064 ;; *) echo "${FUXI_GPT_BYTES:-253340155904}" ;; esac
}
readlink() {
    [ "$FUXI_GPT_CASE" != readlink-failed ] || return 1
    if [ "$FUXI_GPT_CASE" = alias-path ]; then
        case "$2" in */super) echo /dev/block/platform/soc/ufs/sda32 ;; */userdata) echo /dev/block/platform/soc/ufs/sda33 ;; esac
        return
    fi
    case "$2" in */super) echo "${FUXI_GPT_DISK}32" ;; */userdata) echo "${FUXI_GPT_DISK}33" ;; esac
}
stat() {
    [ "$FUXI_GPT_CASE" != stat-failed ] || return 1
    [ "$FUXI_GPT_CASE" != stat-empty ] || return 0
    local path="${@: -1}"
    case "$FUXI_GPT_CASE:$path" in
        conflicting-global:*/by-name/super|conflicting-boot:*/boot-name/super|wrong-userdata:*/userdata) echo 8:1f; return ;;
    esac
    case "$path" in *disk32|*/super) echo 8:20 ;; *disk33|*/userdata) echo 8:21 ;; *) return 1 ;; esac
}
umount() {
    [[ "$FUXI_GPT_CASE" != mount-busy && "$FUXI_GPT_CASE" != cache-busy ]] || return 1
    : > "$FUXI_GPT_MOUNTS"
}
sync() { :; }
source "$FUXI_GPT_SCRIPT" "$1"
''', newline='\n')


def layout(expanded=False):
    return {'case':'valid',
        '32':dict(name='super', type='89A12DE1-5E41-4CB3-8B4C-B1441EB5DA38', guid='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA', first=854080, last=3737663 if expanded else 3213375),
        '33':dict(name='userdata', type='1B81E7E6-F50D-419B-A739-2AEEF8DA3335', guid='BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB', first=3737664 if expanded else 3213376, last=61850618)}


requested=sys.argv[1] if len(sys.argv)>1 else None
results=json.loads((WORK/'results.json').read_text()) if requested else []
results=[x for x in results if x['case'] != requested]
for case in ('expand', 'restore', 'cache-unmount', 'cache-busy', 'bad-gpt', 'bad-checksum', 'missing-backup', 'stale-gpt', 'mount-busy', 'other-mount', 'wrong-device', 'wrong-sector', 'wrong-result', 'missing-confirmation', 'bad-guid', 'disk-bounds', 'current-backup-failed',
             'disk-too-small', 'disk-unaligned', 'disk-invalid', 'disk-too-large',
             'disk-minimum', 'disk-leading-zero', 'disk-512g', 'disk-1t',
             'alias-path', 'bootdevice-only', 'no-aliases', 'conflicting-global',
             'conflicting-boot', 'wrong-userdata', 'broken-super-alias',
             'missing-super-node', 'wrong-super-name', 'wrong-userdata-name',
             'stat-failed', 'stat-empty', 'readlink-failed', 'verify-no-aliases'):
    if requested and case != requested:
        continue
    directory = WORK / case
    directory.mkdir(exist_ok=True)
    state = directory / 'state.json'
    calls = directory / 'calls.jsonl'
    backup = directory / 'backup.bin'
    mounts = directory / 'mounts'
    sector = directory / 'sector'
    disk = directory / 'disk'
    state.write_text(json.dumps(layout(case == 'restore' or case.startswith('verify-'))))
    valid_bytes = {'disk-minimum': str(64 * 1024**3), 'disk-leading-zero': '000253340155904',
                   'disk-512g': str(512 * 1024**3), 'disk-1t': str(1024**4)}
    if case in valid_bytes:
        initial = json.loads(state.read_text())
        initial['33']['last'] = int(valid_bytes[case]) // 4096 - 6
        state.write_text(json.dumps(initial))
    saved_last = json.loads(state.read_text())['33']['last']
    calls.write_text('')
    mounts.write_text('')
    sector.write_text('4096\n')
    disk.write_text('Synthetic block device marker; never real storage\n')
    Path(str(disk) + '32').write_text('Synthetic super block marker\n')
    Path(str(disk) + '33').write_text('Synthetic userdata block marker\n')
    by_name = directory / 'by-name'
    boot_name = directory / 'boot-name'
    for aliases in (by_name, boot_name):
        aliases.mkdir(exist_ok=True)
        for name in ('super', 'userdata'):
            (aliases / name).write_text('Synthetic block alias marker\n')
    env = dict(os.environ, FUXI_GPT_STATE=str(state), FUXI_GPT_LOG=str(calls), FUXI_GPT_CASE='valid',
        FUXI_GPT_BYTES=valid_bytes.get(case, '253340155904'),
        FUXI_GPT_BY_NAME=by_name.as_posix(), FUXI_GPT_BOOT_NAME=boot_name.as_posix(),
        FUXI_GPT_DISK=disk.as_posix(), FUXI_GPT_SCRIPT=(WORK / 'prepare-test.sh').as_posix(),
        FUXI_GPT_SGDISK=fake.as_posix(), FUXI_GPT_BACKUP=backup.as_posix(),
        FUXI_GPT_CURRENT=(directory / 'current.bin').as_posix(), FUXI_GPT_SECTOR=sector.as_posix(), FUXI_GPT_MOUNTS=mounts.as_posix())
    audit=subprocess.run([BASH,str(runner),'audit'], env=env, capture_output=True, timeout=20)
    assert audit.returncode == 0, audit.stdout.decode(errors='replace') + audit.stderr.decode(errors='replace')
    checksum=hashlib.sha256(backup.read_bytes()).hexdigest()
    env['FUXI_GPT_CASE']=case
    s=json.loads(state.read_text())
    s['case']=case
    if case == 'stale-gpt': s['33']['last'] -= 256
    if case == 'bad-guid': s['32']['guid'] = 'invalid'
    if case == 'disk-bounds': s['33']['last'] = 999999999
    if case == 'wrong-super-name': s['32']['name'] = 'other'
    if case == 'wrong-userdata-name': s['33']['name'] = 'other'
    state.write_text(json.dumps(s))
    if case == 'bad-checksum': checksum = '0' * 64
    if case == 'missing-backup': backup.write_bytes(b'')
    if case == 'mount-busy': mounts.write_text('/dev/block/dm-0 /data ext4 rw 0 0\n')
    if case in ('cache-unmount', 'cache-busy'): mounts.write_text('/dev/block/sda29 /cache ext4 rw 0 0\n')
    if case in ('bootdevice-only', 'no-aliases', 'verify-no-aliases'):
        for path in by_name.iterdir(): path.unlink()
    if case in ('no-aliases', 'verify-no-aliases'):
        for path in boot_name.iterdir(): path.unlink()
    if case == 'missing-super-node': Path(str(disk) + '32').unlink()
    if case == 'other-mount': mounts.write_text('/dev/block/sda33 /unhandled ext4 rw 0 0\n')
    if case == 'wrong-sector': sector.write_text('512\n')
    if case == 'current-backup-failed': (directory/'current.bin').write_bytes(backup.read_bytes())
    bad_bytes = {'disk-too-small': str(64 * 1024**3 - 4096), 'disk-unaligned': '253340155905',
                 'disk-invalid': '253340155904x', 'disk-too-large': str(2**53)}
    if case in bad_bytes:
        env['FUXI_GPT_BYTES'] = bad_bytes[case]
    mode='verify' if case.startswith('verify-') else 'restore' if case == 'restore' else 'apply'
    env.update(FUXI_BACKUP_SHA256=checksum, FUXI_CONFIRM='RESTORE_STOCK_SUPER' if mode == 'restore' else 'ERASE_AND_RESIZE')
    if case == 'missing-confirmation': env.pop('FUXI_CONFIRM')
    completed=subprocess.run([BASH,str(runner),mode], env=env, capture_output=True, timeout=20)
    commands=[json.loads(x) for x in calls.read_text().splitlines()]
    writes=[x for x in commands if '--delete=32' in x]
    expected=case in ('expand','restore','cache-unmount','alias-path','bootdevice-only','no-aliases','verify-no-aliases',*valid_bytes)
    ok=(completed.returncode == 0) == expected
    ok=ok and (len(writes) == (1 if (expected and mode != 'verify') or case == 'wrong-result' else 0))
    if expected:
        final=json.loads(state.read_text())
        ok=ok and final['32']['first']==854080 and final['33']['last']==saved_last
        ok=ok and final['32']['last']==(3213375 if mode == 'restore' else 3737663)
        ok=ok and final['33']['first']==final['32']['last']+1
    result=dict(case=case,ok=ok,exit=completed.returncode,gpt_writes=len(writes), numeric_test='signed32')
    results.append(result)
    (directory / 'output.txt').write_bytes(audit.stdout + audit.stderr + completed.stdout + completed.stderr)
    print(json.dumps(result),flush=True)
    if not ok: print((completed.stdout + completed.stderr).decode(errors='replace'),flush=True)
(WORK / 'results.json').write_text(json.dumps(results,indent=2))
assert all(x['ok'] for x in results), 'Recovery regression test failed'
print(f'PASS: {len(results)} mocked recovery scenarios. No real block devices or mounts.',flush=True)
