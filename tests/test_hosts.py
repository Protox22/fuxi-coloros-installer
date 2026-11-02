"""Real entrypoints + synthetic native subprocesses. Assert write order and stops."""
import json
from pathlib import Path
import sys
from concurrent.futures import ThreadPoolExecutor
from host_support import HOSTS, WORK, execute, fixture, native

results = []


def run_case(host, name, *, operation='clean', device='valid', answers='y\ny\n', exit=0,
        stock=False, slot='a', no_writes=False, no_gpt=False, menu=False, **state):
    directory = WORK / (host + '-' + name)
    root = fixture(directory / 'release & spaces (test)! Кириллица')
    options = {'clean': ['-Clean'], 'update': ['-Update'], 'verify': ['-VerifyOnly'], 'restore': [], 'diagnose': []}[operation]
    if host == 'bash': options = [x.replace('-Clean', '--clean').replace('-Update', '--update').replace('-VerifyOnly', '--verify-only') for x in options]
    entry = {'restore': 'restore-super', 'diagnose': 'check-base'}.get(operation, 'flash')
    if menu: entry, options = 'scripts/menu', []
    rc, output, calls = execute(host, root, directory, case=device, entry=entry, options=options,
                               answers=answers, size='0x240000000' if stock else '0x2c0000000', slot=slot, **state)
    fb, adb = native(calls), native(calls, 'adb')
    writes = [x for x in fb if any(p in x for p in ('flash', 'erase', 'set_active'))]
    gpt = [x for x in adb if 'FUXI_CONFIRM=' in ' '.join(x)]
    reboot = [x for x in fb if x == ['reboot']]
    checks = [rc == exit, not (root / '.installer.lock').exists(), '\ufffd' not in output]
    if no_writes: checks += [not writes, not gpt]
    if no_gpt: checks += [not gpt]
    if operation == 'verify': checks += [not calls]
    if operation == 'diagnose': checks += [all(x[:1] in (['devices'], ['getvar']) for x in fb),
                                           all(x[:1] in (['devices'], ['shell']) for x in adb), not writes, not gpt]
    if operation == 'update': checks += [not gpt, all(x[:1] not in (['erase'], ['set_active']) for x in fb),
                                         not any('recovery' in x or 'prepare-super' in ' '.join(x) for x in adb)]
    if rc == 0 and operation in ('clean', 'update') and not no_writes:
        checks += [len(reboot) == 1, len([x for x in fb if x[:2] == ['flash', 'super']]) == 1]
        # Every partition image is required exactly once after the super write.
        tail = fb[fb.index(next(x for x in fb if x[:2] == ['flash', 'super'])):]
        checks += [[x[1] for x in tail if x[:1] == ['flash']] ==
                   ['super', 'boot_a', 'init_boot_a', 'vendor_boot_a', 'dtbo_a', 'recovery_a', 'vbmeta_a', 'vbmeta_system_a']]
        if operation == 'clean':
            checks += [[x for x in fb if x[:1] == ['erase']] == [['erase', 'userdata'], ['erase', 'metadata']],
                       fb.index(['set_active', 'a']) > fb.index(['erase', 'metadata']),
                       fb.index(['getvar', 'current-slot'], fb.index(['set_active', 'a'])) < fb.index(['reboot'])]
    if operation == 'restore': checks += [not reboot, not any('set_active' in x for x in fb)]
    if rc != 0 and device != 'reboot-failed': checks += [not reboot]
    # Temporary sparse image must be cleaned on success, failure and cancellation.
    for c in calls:
        if c[0] == 'zstd': checks += [not Path(c[c.index('-o') + 1]).exists()]
    if device in ('super-write-failed', 'extra-write-failed', 'erase-failed', 'slot-changed'):
        checks += [not any(x[:1] == ['set_active'] for x in fb)]
    result = dict(host=host, case=name, ok=all(checks), exit=rc, calls=len(calls), writes=len(writes), gpt=len(gpt))
    results.append(result)
    print(json.dumps(result), flush=True)
    if not result['ok']: print(output[-4500:], checks, flush=True)


pool = ThreadPoolExecutor(max_workers=4)
pending = []
def run(*args, **kwargs):
    pending.append(pool.submit(run_case, *args, **kwargs))

for host in HOSTS:
    run(host, 'clean-a')
    run(host, 'clean-b', slot='b')
    run(host, 'clean-9g', stock=True)
    run(host, 'clean-b-9g-refused', stock=True, slot='b', exit=1, no_writes=True)
    run(host, 'update', operation='update')
    run(host, 'update-9g-refused', operation='update', stock=True, exit=1, no_writes=True)
    run(host, 'update-b-refused', operation='update', slot='b', exit=1, no_writes=True)
    for answer in ('n\n', '\n', ''):
        run(host, 'cancel-' + str(len(answer)), answers=answer, exit=2, no_writes=True)
    run(host, 'invalid-then-confirm', answers='bad\n Y \n')
    run(host, 'gpt-cancel', stock=True, answers='y\nn\n', exit=1, no_gpt=True)
    run(host, 'restore', operation='restore')
    run(host, 'restore-noop', operation='restore', stock=True, no_writes=True)
    run(host, 'restore-cancel', operation='restore', answers='', exit=2, no_writes=True)
    run(host, 'verify-offline', operation='verify', no_writes=True)
    for case in ('no-devices', 'many-fastboot', 'mixed-devices', 'wrong-product', 'locked', 'fastbootd', 'missing-mode',
                 'getvar-failed', 'unknown-size', 'invalid-size', 'duplicate-var', 'enumeration-error', 'adb-permissions',
                 'adb-garbage', 'extra-too-large', 'recovery-too-large', 'vbmeta-too-large', 'vbmeta-system-too-large',
                 'corrupt-super', 'zstd-failed'):
        run(host, case, device=case, exit=1, no_writes=True)
    for case in ('super-write-failed', 'extra-write-failed', 'erase-failed', 'activation-failed', 'slot-changed', 'reboot-failed'):
        run(host, case, device=case, exit=1)
    run(host, 'activation-ignored', device='activation-ignored', slot='b', exit=1)
    for case in ('corrupt-backup', 'empty-backup', 'wrong-recovery', 'missing-twrp', 'push-failed', 'audit-failed'):
        run(host, case, device=case, stock=True, exit=1, no_gpt=True)
    for case in ('resize-wrong-size', 'gpt-failed'):
        run(host, case, device=case, stock=True, exit=1)
    run(host, 'padded-size', device='padded-size')
    run(host, 'padded-required-sizes', device='padded-required-sizes')
    run(host, 'adb-entry', adb_mode=True)
    run(host, 'wrong-adb-product', device='wrong-adb-product', adb_mode=True, exit=1, no_writes=True)
    run(host, 'diagnose-fastboot', operation='diagnose')
    for case in ('base-match', 'base-mismatch', 'base-missing', 'base-mixed-boot', 'base-recovery', 'base-booting'):
        run(host, case, device=case, operation='diagnose', adb_mode=True)
    run(host, 'base-unauthorized', device='base-unauthorized', operation='diagnose', adb_mode=True, exit=1)
    run(host, 'menu-clean', menu=True, answers='1\n1\ny\n0\n')
    run(host, 'menu-update', menu=True, operation='update', answers='1\n2\ny\n0\n')
    run(host, 'menu-retry-after-cancel', menu=True, answers='1\n1\nn\n1\n1\ny\n0\n')

for future in pending: future.result()
pool.shutdown()
(WORK / 'results.json').write_text(json.dumps(sorted(results, key=lambda x: (x['host'], x['case'])), indent=2))
print('Host results: ' + str(WORK / 'results.json'))
sys.exit(0 if all(x['ok'] for x in results) else 1)
