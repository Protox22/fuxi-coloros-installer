"""Fake sgdisk used only on JSON fixtures by test_gpt.py."""
import json
import os
from pathlib import Path
import sys

p = Path(os.environ['FUXI_GPT_STATE'])
s = json.loads(p.read_text())
args = sys.argv[1:]
with Path(os.environ['FUXI_GPT_LOG']).open('a') as log:
    log.write(json.dumps(args) + '\n')
parts = {k:v for k,v in s.items() if k.isdigit()}
if args[0] == '--print':
    print('Disk /dev/block/sda: 61850624 sectors, 235.9 GiB')
    print('Sector size (logical/physical): 4096/4096 bytes')
    print('Partition table holds up to ' + str(s.get('capacity',128)) + ' entries')
    print('Number Start (sector) End (sector) Size Code Name')
    for key in sorted(parts,key=int):
        part=parts[key]
        print(f"{key} {part['first']} {part['last']} 1.0 GiB FFFF {part['name']}")
elif args[0].startswith('--info='):
    n = int(args[0].split('=')[1])
    part = s[str(n)]
    print('Partition GUID code: ' + part['type'] + ' (Unknown)')
    print('Partition unique GUID: ' + part['guid'])
    print('First sector: ' + str(part['first']) + ' (at 0 B)')
    print('Last sector: ' + str(part['last']) + ' (at 0 B)')
    print('Attribute flags: ' + part.get('attrs','0000000000000000'))
    print("Partition name: '" + part['name'] + "'")
elif args[0] == '--verify':
    # The damaged case deliberately exits zero, as real sgdisk --verify can do.
    ranges=sorted((p['first'],p['last']) for p in parts.values())
    overlap=any(a[1]>=b[0] for a,b in zip(ranges,ranges[1:]))
    print('Identified 1 problems!' if s['case'] == 'bad-gpt' or overlap else 'No problems found. 0 free sectors available.')
elif args[0].startswith('--backup='):
    if s['case'] == 'current-backup-failed' and args[0].endswith('current.bin'):
        sys.exit(0) # Some sgdisk versions ignore the backup writer's failure result.
    snapshot=dict(partitions=parts,capacity=s.get('capacity',128),disk_guid=s.get('disk_guid','TEST-DISK-GUID'))
    Path(args[0].split('=', 1)[1]).write_text(json.dumps(snapshot, sort_keys=True))
elif any(a.startswith('--delete=') for a in args):
    assert args[0] == '--set-alignment=1', 'Exact sector alignment is mandatory'
    numbers=[int(a.split('=',1)[1]) for a in args if a.startswith('--delete=')]
    assert len(numbers)==2 and [s[str(n)]['name'] for n in numbers]==['super','userdata']
    untouched={k:dict(v) for k,v in parts.items() if int(k) not in numbers}
    for n in numbers:
        assert 1<=n<=s.get('capacity',128), 'Do not create a GPT entry outside the existing table'
        part = s[str(n)]
        assert f'--partition-guid={n}:{part["guid"]}' in args
        assert f'--typecode={n}:{part["type"]}' in args
        assert f'--change-name={n}:{part["name"]}' in args
        new = next(a for a in args if a.startswith(f'--new={n}:'))
        _, first, last = new.split(':')
        part['first'], part['last'] = int(first), int(last)
    if s['case'] == 'wrong-result':
        s[str(numbers[0])]['last'] -= 1
    assert all(s[k]==v for k,v in untouched.items()), 'An unrelated partition changed'
    p.write_text(json.dumps(s))
else:
    raise AssertionError(args)
