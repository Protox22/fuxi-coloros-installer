"""Wizard navigation, build selection, Unicode and native process deadlines."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import sys
from host_support import BASE, HOSTS, PS, TOOLS, WORK, command, environment, execute, fixture, native, sums

def run(host, case):
    directory = WORK / (host + '-' + case)
    root = fixture(directory / 'release & spaces (test)! Кириллица')
    answers = {'exit': '0\n', 'eof': '', 'invalid': 'oops\n0\n', 'back': '1\n0\n0\n',
               'mode-invalid': '1\nwrong\n0\n0\n', 'languages': 'L\nL\nL\n0\n',
               'verify-twice': '3\n3\n0\n', 'failed-verify-twice': '3\n3\n0\n', 'partial': '3\n0\n', 'help': '5\n0\n', 'report-empty': '6\n0\n',
               'ksu': '1\n1\n2\ny\n0\n', 'no-root': '1\n2\n2\ny\n0\n',
               'bad-marker': '1\n1\n2\ny\n0\n0\n', 'bad-shell': '1\n1\n2\ny\n0\n0\n'}[case]
    if case == 'partial': (root / 'images/super.img.zst').unlink()
    if case == 'failed-verify-twice': (root / 'images/recovery.img').write_bytes(b'bad')
    selected = root
    if case in ('ksu', 'no-root', 'bad-marker', 'bad-shell'):
        build = 'no-root' if case == 'no-root' else 'ksu'
        selected = fixture(root.parent / ('FUXI-NO-ROOT' if build == 'no-root' else 'FUXI-KSU'))
        (selected / 'BUILD_TYPE.txt').write_text(build + '\n')
        sums(selected)
        if case == 'bad-marker': (selected / 'BUILD_TYPE.txt').write_text('changed\n')
        if case == 'bad-shell':
            p = selected / 'scripts/common.sh'; p.write_bytes(p.read_bytes() + b'\n# old shell\n')
            sums(selected)
    rc, output, calls = execute(host, root, directory, entry='scripts/menu', answers=answers)
    if case in ('ksu', 'no-root'):
        fb = native(calls)
        okay = rc == 0 and ['reboot'] in fb and not any(x[:1] in (['erase'], ['set_active']) for x in fb)
        okay &= bool(list((selected / 'logs').glob('*.log'))) and not (root / 'logs').exists()
    elif case in ('bad-marker', 'bad-shell'):
        okay = not calls  # Menu may return to a build choice or report operation failure.
    else:
        okay = rc == (1 if case in ('failed-verify-twice','report-empty') else 0) and not calls
    okay &= '\ufffd' not in output and not (root / '.installer.lock').exists()
    if case == 'languages': okay &= all(text in output for text in ('Инструкция', 'Instructions', 'Instrukcja'))
    if case in ('verify-twice', 'failed-verify-twice'): okay &= len(list((root / 'logs').glob('*.log'))) == 2
    result = dict(host=host, case=case, ok=bool(okay), exit=rc)
    print(json.dumps(result), flush=True)
    if not okay: print(output[-4000:], flush=True)
    return result


with ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(lambda pair: run(*pair), [(h,c) for h in HOSTS for c in
                   ('exit', 'eof', 'invalid', 'back', 'mode-invalid', 'languages', 'verify-twice', 'failed-verify-twice', 'partial', 'help', 'report-empty', 'ksu', 'no-root', 'bad-marker', 'bad-shell')]))

if os.name == 'nt':
    directory = WORK / 'native-process'
    root = fixture(directory / 'release')
    env, calls = environment(directory)
    script = directory / 'deadline.ps1'
    script.write_text('''$Language='en'
. "''' + str(root / 'scripts/common.ps1') + r'''"
$failed = $false
$timer = [Diagnostics.Stopwatch]::StartNew()
try { Invoke-Tool $Fastboot @('test-timeout') -TimeoutSeconds 1 }
catch { $failed = $_.Exception.Message -like '*Timed out*' }
if (-not $failed -or $timer.Elapsed.TotalSeconds -gt 8) { exit 1 }
# Verify native argument serialization independently of the production parser.
$expected = @('echo-args', 'space value', 'amp&bang!', 'quote"value', 'C:\path with space\', 'Кириллица')
$actual = (Invoke-Tool $Fastboot $expected -Quiet) -join '' | ConvertFrom-Json
if (($actual | ConvertTo-Json -Compress) -cne ($expected | ConvertTo-Json -Compress)) { exit 1 }
exit 0
''', encoding='utf-8-sig')
    p = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)], env=env, capture_output=True, timeout=15)
    result = dict(host='windows', case='native-timeout-and-arguments', ok=p.returncode == 0)
    results.append(result)
    print(json.dumps(result), flush=True)
    if p.returncode: print((p.stdout+p.stderr).decode(errors='replace'))

(WORK / 'results.json').write_text(json.dumps(results, indent=2))
print('UI results: ' + str(WORK / 'results.json'))
sys.exit(0 if all(x['ok'] for x in results) else 1)
