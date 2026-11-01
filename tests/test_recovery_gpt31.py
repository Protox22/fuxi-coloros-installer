"""Exercise the user's full 32-entry table without USB or real block devices."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid
import shutil

BASE=Path(__file__).resolve().parent
ROOT=BASE.parent/'installer'
WORK=BASE/'.work'/('gpt31-' + uuid.uuid4().hex[:8])
WORK.mkdir(parents=True)
BASH='C:/Program Files/Git/bin/bash.exe' if os.name == 'nt' else shutil.which('bash')
script=(ROOT/'scripts/prepare-super.sh').read_text()
for old,new in {'DISK=/dev/block/sda':'DISK="$FUXI_GPT_DISK"',
                'SGDISK=/system/bin/sgdisk':'SGDISK="$FUXI_GPT_SGDISK"',
                'BACKUP=/tmp/fuxi-gpt-before.bin':'BACKUP="$FUXI_GPT_BACKUP"',
                'CURRENT=/tmp/fuxi-gpt-current.bin':'CURRENT="$FUXI_GPT_CURRENT"',
                '[ -b ':'[ -f ',
                '/dev/block/bootdevice/by-name':'"$FUXI_GPT_BOOT_NAME"',
                '/dev/block/by-name':'"$FUXI_GPT_BY_NAME"',
                '/sys/class/block/sda/queue/logical_block_size':'"$FUXI_GPT_SECTOR"',
                '/proc/mounts':'"$FUXI_GPT_MOUNTS"'}.items():
    assert old in script,old
    script=script.replace(old,new)
(WORK/'script.sh').write_text(script,encoding='ascii',newline='\n')
(WORK/'sgdisk').write_text(f'#!/usr/bin/env bash\nexec "{Path(sys.executable).as_posix()}" "{(BASE/"mock_gpt.py").as_posix()}" "$@"\n',encoding='utf-8',newline='\n')
(WORK/'runner.sh').write_text('''#!/usr/bin/env bash
set -eu
function [() {
    if [[ $# = 4 && $2 =~ ^-(eq|ne|lt|le|gt|ge)$ && $1 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]]; then
        local left right
        left=$((10#$1 & 4294967295)); right=$((10#$3 & 4294967295))
        if ((left >= 2147483648)); then left=$((left - 4294967296)); fi
        if ((right >= 2147483648)); then right=$((right - 4294967296)); fi
        builtin [ "$left" "$2" "$right" ]
    else builtin [ "$@"; fi
}
getprop() { case "$1" in ro.product.device) echo fuxi ;; *) echo 900 ;; esac; }
blockdev() { case "$2" in *disk31|*/super) echo 11811160064 ;; *) echo 253340155904 ;; esac; }
readlink() { case "$2" in */super) echo "${FUXI_GPT_DISK}31" ;; */userdata) echo "${FUXI_GPT_DISK}32" ;; esac; }
stat() {
    local path="${@: -1}"
    if [[ "$FUXI_GPT_CASE" = alias-conflict && "$path" = */super ]]; then echo 103:e; return; fi
    case "$path" in *disk31|*/super) echo 103:f ;; *disk32|*/userdata) echo 103:10 ;; *) return 1 ;; esac
}
umount() { [ "$FUXI_GPT_CASE" != busy-cache ] || return 1; : > "$FUXI_GPT_MOUNTS"; }
sync() { :; }
source "$FUXI_GPT_SCRIPT" "$1"
''',encoding='ascii',newline='\n')

ROWS='''1 6 7 switch
2 8 15 ssd
3 16 23 dbg
4 24 31 bk01
5 32 63 bk02
6 64 127 bk03
7 128 255 bk04
8 256 383 keystore
9 384 511 frp
10 512 1023 countrycode
11 1024 2047 misc
12 2048 4095 bk05
13 4096 6143 logfs
14 6144 8191 ffu
15 8192 12287 devinfo
16 12288 16383 oops
17 16384 32767 metadata
18 32768 49151 persist
19 49152 57343 mtdblk
20 57344 72191 crash_history
21 72192 96767 minidump
22 96768 173567 rawdump
23 173568 180223 bk010
24 180224 180255 vbmeta_system_a
25 180256 180287 vbmeta_system_b
26 180288 181311 mem
27 181312 186431 opconfig
28 186432 194623 mbnconfig
29 194624 227391 rescue
30 227392 751679 cust
31 751680 3110975 super
32 3110976 61850618 userdata'''


def layout(expanded=False):
    result=dict(case='valid',capacity=32,disk_guid='CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC')
    for row in ROWS.splitlines():
        n,first,last,name=row.split()
        result[n]=dict(name=name,first=int(first),last=int(last),type='TEST-UNTOUCHED-TYPE',guid=str(uuid.uuid5(uuid.NAMESPACE_OID,n)).upper())
    result['31'].update(type='89A12DE1-5E41-4CB3-8B4C-B1441EB5DA38',guid='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
    result['32'].update(type='1B81E7E6-F50D-419B-A739-2AEEF8DA3335',guid='BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB')
    if expanded: result['31']['last']=3635263; result['32']['first']=3635264
    return result


results=[]
for case in ('expand','restore','verify','audit','already-expanded','already-stock',
             'wrong-type','wrong-start','wrong-boundary','alias-conflict','stale-backup',
             'missing-confirm','attrs','bad-gpt','disk-bounds','duplicate-super',
             'wrong-guid','busy-cache','changed-disk-guid'):
    folder=WORK/case
    folder.mkdir()
    state=folder/'state.json'
    initial=layout(case in ('restore','verify','already-expanded'))
    untouched={k:v for k,v in initial.items() if k not in ('31','32','case')}
    state.write_text(json.dumps(initial))
    log=folder/'calls.jsonl'; log.write_text('')
    backup=folder/'backup.bin'
    disk=folder/'disk'; disk.write_text('Synthetic block marker')
    for n in (31,32): Path(str(disk)+str(n)).write_text('Synthetic partition node')
    aliases=folder/'by-name'; aliases.mkdir()
    boot=folder/'boot-name'; boot.mkdir()
    for directory in (aliases,boot):
        for name in ('super','userdata'): (directory/name).write_text('Synthetic block alias')
    sector=folder/'sector'; sector.write_text('4096\n')
    mounts=folder/'mounts'; mounts.write_text('')
    env=dict(os.environ,FUXI_GPT_STATE=str(state),FUXI_GPT_LOG=str(log),FUXI_GPT_CASE='valid',
             FUXI_GPT_DISK=disk.as_posix(),FUXI_GPT_SCRIPT=(WORK/'script.sh').as_posix(),
             FUXI_GPT_SGDISK=(WORK/'sgdisk').as_posix(),FUXI_GPT_BACKUP=backup.as_posix(),
             FUXI_GPT_CURRENT=(folder/'current.bin').as_posix(),FUXI_GPT_BY_NAME=aliases.as_posix(),
             FUXI_GPT_BOOT_NAME=boot.as_posix(),FUXI_GPT_SECTOR=sector.as_posix(),FUXI_GPT_MOUNTS=mounts.as_posix())
    audit=subprocess.run([BASH,str(WORK/'runner.sh'),'audit'],env=env,capture_output=True,timeout=30)
    assert audit.returncode==0,(case,(audit.stdout+audit.stderr).decode(errors='replace'))
    env['FUXI_BACKUP_SHA256']=hashlib.sha256(backup.read_bytes()).hexdigest()
    env['FUXI_GPT_CASE']=case
    current=json.loads(state.read_text()); current['case']=case
    if case=='wrong-type': current['32']['type']='00000000-0000-0000-0000-000000000000'
    if case=='wrong-start': current['31']['first']+=1
    if case=='wrong-boundary': current['32']['first']+=1
    if case=='stale-backup': current['30']['guid']='00000000-0000-0000-0000-000000000001'
    if case=='attrs': current['31']['attrs']='0000000000000001'
    if case=='disk-bounds': current['32']['last']=61850624
    if case=='duplicate-super': current['30']['name']='super'
    if case=='wrong-guid': current['31']['guid']='invalid'
    if case=='changed-disk-guid': current['disk_guid']='DIFFERENT-DISK-GUID'
    if case=='busy-cache': mounts.write_text('/dev/block/sda29 /cache ext4 rw 0 0\n')
    state.write_text(json.dumps(current))
    mode='restore' if case in ('restore','already-stock') else case if case in ('audit','verify') else 'apply'
    env['FUXI_CONFIRM']='RESTORE_STOCK_SUPER' if mode=='restore' else 'ERASE_AND_RESIZE'
    if case=='missing-confirm': del env['FUXI_CONFIRM']
    run=subprocess.run([BASH,str(WORK/'runner.sh'),mode],env=env,capture_output=True,timeout=30)
    calls=[json.loads(line) for line in log.read_text().splitlines()]
    writes=[args for args in calls if any(a.startswith('--delete=') for a in args)]
    expected=case in ('expand','restore','verify','audit','already-expanded','already-stock')
    should_write=case in ('expand','restore')
    ok=(run.returncode==0)==expected and len(writes)==int(should_write)
    if should_write:
        final=json.loads(state.read_text())
        ok=ok and all(final[k]==v for k,v in untouched.items())
        ok=ok and final['31']['guid']==initial['31']['guid'] and final['32']['guid']==initial['32']['guid']
        ok=ok and final['31']['first']==751680 and final['32']['last']==61850618
        ok=ok and final['31']['last']==(3110975 if mode=='restore' else 3635263)
        ok=ok and final['32']['first']==final['31']['last']+1
        ok=ok and [a for a in writes[0] if a.startswith('--delete=')]==['--delete=31','--delete=32']
    (folder/'output.txt').write_bytes(audit.stdout+audit.stderr+run.stdout+run.stderr)
    result=dict(case=case,ok=bool(ok),exit=run.returncode,gpt_writes=len(writes),geometry='31/32@751680',untouched_partitions=30,real_block_device=False)
    results.append(result)
    (WORK/'results.json').write_text(json.dumps(results,indent=2))
    print(json.dumps(result),flush=True)
    if not ok: print((run.stdout+run.stderr).decode(errors='replace'),flush=True)
    assert ok,case
print(f'PASS: {len(results)} full-table GPT31 scenarios; all real disk operations mocked.',flush=True)
