"""Synthetic subprocess used by tests only. Never contacts USB or block devices."""
import hashlib
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ['FUXI_TEST_STATE'])
state = json.loads(state_path.read_text())
serial = state.get('serial', 'TEST-SERIAL')
kind, *args = sys.argv[1:]
with Path(os.environ['FUXI_TEST_LOG']).open('a', encoding='utf-8') as log:
    log.write(json.dumps([kind, *args]) + '\n')
if args[:1] == ['-s']:
    if args[1] != serial:
        print('Unexpected device serial', file=sys.stderr)
        sys.exit(1)
    args = args[2:]
case = state['case']
size = state.get('size', '0x2c0000000')
backup = b'Synthetic GPT backup for regression tests only\n'
code = 0
if args[:1] == ['echo-args']:
    print(json.dumps(args, ensure_ascii=False))
    sys.exit(0)
if kind == 'fastboot':
    if args == ['devices']:
        if case == 'enumeration-error':
            print('ERROR no permissions')
        elif case == 'no-devices' or state.get('adb_mode'):
            pass
        elif case == 'many-fastboot':
            print(serial + '\tfastboot\nSECOND\tfastboot')
        else:
            print(serial + '\tfastboot')
    elif args[:1] == ['getvar']:
        values = {'product': 'other' if case == 'wrong-product' else 'fuxi',
                  'current-slot': state.get('slot', 'a'),
                  'unlocked': 'no' if case == 'locked' else 'yes',
                  'is-userspace': 'yes' if case == 'fastbootd' else 'no',
                  'partition-size:super': '0x00000002c0000000' if case == 'padded-size' else size}
        if args[1].startswith('partition-size:') and args[1] != 'partition-size:super':
            values[args[1]] = '0x10' if case == 'extra-too-large' else '0x4000000'
            if case == 'padded-required-sizes':
                values[args[1]] = '0x0000000004000000'
            if case in ('recovery-too-large', 'vbmeta-too-large', 'vbmeta-system-too-large'):
                target = {'recovery-too-large': 'recovery_a', 'vbmeta-too-large': 'vbmeta_a',
                          'vbmeta-system-too-large': 'vbmeta_system_a'}[case]
                if args[1] == 'partition-size:' + target:
                    values[args[1]] = '0x10'
            if case == 'twrp-too-large' and args[1] == 'partition-size:recovery_' + state.get('slot', 'a'):
                values[args[1]] = '0x20'
        if case == 'duplicate-var':
            print('(bootloader) ' + args[1] + ': ' + values[args[1]], file=sys.stderr)
        if case == 'slot-changed' and state.get('flashed') and args[1] == 'current-slot':
            values[args[1]] = 'b'
        if case == 'invalid-size' and args[1] == 'partition-size:super':
            values[args[1]] = 'not-hex'
        if case == 'unknown-size' and args[1] == 'partition-size:super':
            values[args[1]] = '0x12340000'
        if case == 'missing-mode' and args[1] == 'is-userspace':
            print('FAILED unknown variable', file=sys.stderr)
            code = 1
        else:
            print('(bootloader) ' + args[1] + ': ' + values[args[1]], file=sys.stderr)
            if case == 'getvar-failed':
                code = 1
    elif args[:2] == ['flash', 'super']:
        state['flashed'] = True
        if case == 'super-write-failed' or not Path(args[-1]).is_file():
            code = 1
    elif args == ['set_active', 'a']:
        if case == 'activation-failed': code = 1
        elif case != 'activation-ignored': state['slot'] = 'a'
    elif args == ['reboot'] and case == 'reboot-failed':
        code = 1
    elif args[:2] == ['erase', 'metadata'] and case == 'erase-failed':
        code = 1
    elif args[:2] == ['erase', 'userdata'] and case == 'userdata-erase-failed':
        code = 1
    elif args[:2] == ['flash', 'recovery_a'] and case == 'restored-recovery-failed' and size == '0x240000000':
        code = 1
    elif args[:2] == ['flash', 'boot_a'] and case == 'extra-write-failed':
        code = 1
elif kind == 'adb':
    if args == ['devices']:
        print('List of devices attached')
        if case == 'adb-permissions': print('????????????\tno permissions (udev rules missing)')
        if case == 'adb-garbage': print('unrecognized output')
        if state.get('adb_mode'):
            print(serial + '\t' + ('unauthorized' if case == 'base-unauthorized' else 'device'))
        if case == 'mixed-devices':
            print('OTHER\tdevice')
    elif args == ['reboot', 'bootloader']:
        state['adb_mode'] = False
    elif args == ['get-state']:
        print('recovery')
    elif args[:2] == ['shell', 'getprop']:
        if args[-1] == 'ro.product.device':
            print('other' if case in ('wrong-adb-product', 'wrong-recovery', 'base-wrong-product') else 'fuxi')
        elif case.startswith('base-'):
            base = os.environ.get('FUXI_TEST_BASE', 'OS3.0.306.0.WMCMIXM')
            values = {
                'ro.twrp.version.skkk.code': 'TEST-TWRP' if case == 'base-recovery' else '',
                'ro.bootmode': 'normal', 'sys.boot_completed': '0' if case == 'base-booting' else '1',
                'ro.build.version.incremental': 'OS3.OTHER' if case == 'base-mismatch' else base,
                'ro.vendor.build.version.incremental': base,
                'ro.bootimage.build.version.incremental': ('' if case == 'base-missing' else
                                                         'OS3.OTHER' if case == 'base-mixed-boot' else base),
            }
            print(values.get(args[-1], 'Xiaomi/fuxi_global/fuxi:16/' + base + '/test:user/release-keys'))
        else:
            print('' if case == 'missing-twrp' else 'TEST-TWRP')
    elif args[:1] == ['shell'] and 'sha256sum' in ' '.join(args[1:]):
        print(hashlib.sha256(backup).hexdigest() + '  /tmp/fuxi-gpt-before.bin')
    elif args[:1] == ['shell']:
        command = ' '.join(args[1:])
        if case == 'audit-failed' and command.endswith(' audit'): code = 1
        if case == 'gpt-failed' and 'FUXI_CONFIRM=' in command: code = 1
        if 'FUXI_CONFIRM=' in command and case != 'resize-wrong-size':
            state['size'] = '0x240000000' if command.endswith(' restore') else '0x2c0000000'
    elif args[:1] == ['pull']:
        content = b'' if case == 'empty-backup' else b'bad GPT' if case == 'corrupt-backup' else backup
        Path(args[-1]).write_bytes(content)
    elif args[:1] == ['push'] and case == 'push-failed':
        code = 1
elif kind == 'zstd':
    path = Path(args[args.index('-o') + 1])
    path.write_bytes(b'CORRUPT' if case == 'corrupt-super' else b'Synthetic sparse image for orchestration tests\n')
    if case == 'zstd-failed': code = 1
state_path.write_text(json.dumps(state))
sys.exit(code)
