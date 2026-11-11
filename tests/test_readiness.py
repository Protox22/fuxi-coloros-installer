"""Read-only readiness, partial-write evidence, and export allowlist/privacy."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile
from host_support import HOSTS, WORK, TOOLS, BASH, PS, command, environment, execute, fixture, native, sums

# Git Bash does not ship zip; test its export flow with a Python ZIP backend.
# Linux CI uses its real zip command when installed.
zip_backend = TOOLS / 'zip_backend.py'
zip_backend.write_text('import sys,zipfile\nwith zipfile.ZipFile(sys.argv[2],"w") as z:\n for p in sys.argv[3:]: z.write(p,p)\n')
zip_shim = TOOLS / 'zip'
zip_shim.write_text('#!/usr/bin/env bash\nexport LC_ALL=C.UTF-8\nexec "'+Path(sys.executable).as_posix()+'" "'+zip_backend.as_posix()+'" "$@"\n',encoding='utf-8',newline='\n')
zip_shim.chmod(0o755)

def run(host, case):
    directory=WORK/(host+'-'+case)
    root=fixture(directory/'release & spaces РљРёСЂРёР»Р»РёС†Р°')
    if case in ('missing-super','missing-boot'): (root/'images'/('super.img.zst' if case=='missing-super' else 'boot.img')).unlink()
    if case in ('corrupt-super','verify-corrupt'): (root/'images/super.img.zst').write_bytes(b'BROKEN')
    if case=='bad-tool': (root/'scripts/process.ps1').write_bytes(b'#bad\n')
    if case=='no-space':
        # Override only the host free-space primitive in a checksummed test copy.
        p=root/('scripts/status.ps1' if host=='windows' else 'scripts/status.sh')
        s=p.read_text(encoding='utf-8-sig')
        if host=='windows': s=s.replace('$drive.AvailableFreeSpace -ge $SuperSparseBytes + 1073741824','$false')
        else: s=s.replace('"$((free * 1024))" -ge "$((SUPER_SPARSE_BYTES + 1073741824))"','0 -ge 999')
        p.write_text(s,encoding='utf-8-sig' if host=='windows' else 'utf-8',newline='\n'); sums(root)
    device={'locked':'locked','fastbootd':'fastbootd','wrong-phone':'wrong-product','no-phone':'no-devices',
            'write-failed':'super-write-failed','erase-failed':'erase-failed','gpt-failed':'gpt-failed','base-success':'base-match'}.get(case,'valid')
    is_write=case in ('write-failed','erase-failed','gpt-failed','cancel-gpt','clean-success','cancel','restore-success','restore-noop','update-success')
    entry='restore-super' if case.startswith('restore-') else 'flash' if is_write or case in ('verify-corrupt','verify-success') else 'check-base'
    options=(['-Clean'] if host=='windows' else ['--clean']) if is_write else (['-VerifyOnly'] if host=='windows' else ['--verify-only']) if case in ('verify-corrupt','verify-success') else []
    if case=='update-success': options=['-Update'] if host=='windows' else ['--update']
    if case.startswith('restore-'): options=[]
    if host=='windows': options+=['-Language','en']
    answers='n\n' if case=='cancel' else 'y\nn\n' if case=='cancel-gpt' else 'y\ny\n'
    rc,output,calls=execute(host,root,directory,case=device,entry=entry,options=options,answers=answers,
                           slot='b' if case in ('slot-b','cancel-gpt') else 'a',
                           size='0x240000000' if case in ('slot-b','stock','gpt-failed','cancel-gpt','restore-noop') else '0x2c0000000',
                           adb_mode=case=='base-success')
    traces=list((root/'logs').glob('*.events.tsv')); trace=traces[-1].read_text() if traces else ''
    expected=1 if case in ('bad-tool','wrong-phone','no-phone','write-failed','erase-failed','gpt-failed','cancel-gpt','verify-corrupt') else 2 if case=='cancel' else 0
    okay=rc==expected and not (root/'.installer.lock').exists()
    if expected==0: okay &= 'result\tfinished' in trace and 'result\tunfinished' not in trace
    if not is_write:
        okay &= not any('flash' in c or 'erase' in c or 'set_active' in c or 'reboot' in c or 'FUXI_CONFIRM=' in ' '.join(c) for c in calls)
    if case in ('missing-super','missing-boot'): okay &= 'ready.bundlePresent\tBLOCKED' in trace
    if case=='corrupt-super': okay &= 'ready.firmwareHashes\tUNKNOWN' in trace
    if case=='no-space': okay &= 'ready.diskSpace\tBLOCKED' in trace
    if case in ('stock','slot-b','locked','fastbootd'): okay &= 'ready.updateTechnical\tBLOCKED' in trace
    if case=='write-failed': okay &= 'flash.super\tstarted' in trace and 'flash.super\tdone' not in trace and 'result\tfailed' in trace
    if case=='gpt-failed': okay &= 'gpt.resize\tstarted' in trace and 'gpt.resize\tdone' not in trace
    if case=='slot-b': okay &= 'ready.cleanTechnical\tOK' in trace
    if case=='cancel-gpt':
        okay &= 'gpt.resize\tstarted' not in trace and 'flash.super' not in trace
        okay &= all(f'flash.{name}_b\tdone' in trace for name in ('recovery', 'vbmeta', 'vbmeta_system'))
        okay &= 'No partition/GPT write commands' not in output
    if case=='cancel': okay &= 'result\tcancelled' in trace and 'flash.super' not in trace
    if case=='verify-corrupt' or case=='bad-tool': okay &= not calls
    if case=='restore-noop': okay &= 'flash.recovery_a' not in trace and 'gpt.resize' not in trace
    if case=='update-success': okay &= 'erase.userdata' not in trace and 'gpt.resize' not in trace and 'activate.a' not in trace
    if case in ('verify-corrupt','bad-tool','wrong-phone','no-phone'):
        okay &= 'No partition/GPT write commands' in output and 'Last attempted write:' not in output
    if traces:
        with traces[-1].open('a') as stream:
            stream.write('SECRET-SERIAL-123\tPRIVATE-PATH\nflash.super\tSECRET-SERIAL-123\nready.compatibility\tUNKNOWN\n')
        (root/'logs/private.log').write_text('SECRET-SERIAL-123 '+str(root), encoding='utf-8')
        env,callfile=environment(directory)
        if host=='bash' and os.name=='nt': env['PATH']=str(TOOLS)+os.pathsep+env['PATH']
        p=subprocess.run(command(host,root,'support-report'),env=env,input=b'',capture_output=True,timeout=40)
        (directory/'export-output.txt').write_bytes(p.stdout+p.stderr)
        reports=list((root/'reports').glob('*.zip'))
        okay &= p.returncode==0 and len(reports)==1 and not callfile.read_text() and not (root/'.installer.lock').exists()
        if reports:
            with zipfile.ZipFile(reports[0]) as z:
                text=''.join(z.read(n).decode('utf-8-sig') for n in z.namelist())
                okay &= set(z.namelist())=={'events.tsv','README.txt'} and 'SECRET-SERIAL-123' not in text and str(root) not in text
                if case=='cancel-gpt':
                    okay &= all(f'flash.{name}_b\tdone' in text for name in ('recovery', 'vbmeta', 'vbmeta_system'))
        if p.returncode: print((p.stdout+p.stderr).decode(errors='replace'))
    record=dict(host=host,case=case,ok=bool(okay),exit=rc)
    print(json.dumps(record),flush=True)
    if not okay: print(output[-2500:],trace,flush=True)
    return record

def run_interrupt(after_write):
    directory=WORK/('windows-pipeline-stop-'+str(after_write))
    root=fixture(directory/'release & spaces Кириллица')
    marker=directory/'started'
    script=directory/'stop.ps1'
    script.write_text('''param([string]$Root,[string]$Marker,[int]$AfterWrite)
$worker=[powershell]::Create()
try {
    [void]$worker.AddScript({param($Root,$Marker,$AfterWrite)
        $Compact=$false; $Language='en'
        . (Join-Path $Root 'scripts/common.ps1')
        try {
            Start-Session 'flash'
            if ($AfterWrite) { Write-Event 'flash.super' 'started' }
            [IO.File]::WriteAllText($Marker,'started')
            Start-Sleep -Seconds 60
            $script:SessionOutcome='finished'
        } finally { Stop-Session }
    }).AddArgument($Root).AddArgument($Marker).AddArgument($AfterWrite)
    $pending=$worker.BeginInvoke()
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Marker)) {
        if ($timer.Elapsed.TotalSeconds -gt 10) { throw 'Worker never started' }
        Start-Sleep -Milliseconds 30
    }
    $worker.Stop()
    try { [void]$worker.EndInvoke($pending) } catch [System.Management.Automation.PipelineStoppedException] {}
} finally { $worker.Dispose() }
''',encoding='utf-8-sig',newline='\n')
    env,callfile=environment(directory)
    p=subprocess.run([str(PS),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(script),str(root),str(marker),str(int(after_write))],env=env,capture_output=True,timeout=25)
    (directory/'output.txt').write_bytes(p.stdout+p.stderr)
    traces=list((root/'logs').glob('*.events.tsv'))
    trace=traces[0].read_text() if traces else ''
    okay=p.returncode==0 and not callfile.read_text() and not (root/'.installer.lock').exists()
    okay &= 'result\tunfinished' in trace and 'result\tfinished' not in trace
    if after_write: okay &= 'flash.super\tstarted' in trace and 'flash.super\tdone' not in trace
    export=subprocess.run(command('windows',root,'support-report'),env=env,capture_output=True,timeout=30)
    reports=list((root/'reports').glob('*.zip'))
    okay &= export.returncode==0 and len(reports)==1
    if reports:
        with zipfile.ZipFile(reports[0]) as z: okay &= b'result\tunfinished' in z.read('events.tsv')
    record=dict(host='windows',case='pipeline-stop-after-write' if after_write else 'pipeline-stop-before-write',ok=bool(okay),exit=p.returncode)
    print(json.dumps(record),flush=True)
    if not okay: print((p.stdout+p.stderr+export.stdout+export.stderr).decode(errors='replace'),trace,flush=True)
    return record

def run_export(host, case):
    directory=WORK/(host+'-export-'+case)
    root=fixture(directory/'release & spaces РљРёСЂРёР»Р»РёС†Р°')
    logs=root/'logs'; logs.mkdir()
    valid='session.flash\tstarted\nflash.super\tstarted\nresult\tfailed\n'
    if case!='empty':
        journal=logs/'session.events.tsv'
        journal.write_text(valid if case!='invalid-header' else 'PRIVATE-SERIAL\tstarted\n')
        if case=='oversize': journal.write_text(valid+'x'*8388609)
        if case=='newest':
            os.utime(journal,(100,100))
            (logs/'new.events.tsv').write_text('session.check-base\tstarted\nready.compatibility\tUNKNOWN\nresult\tfinished\n')
            (logs/'export.events.tsv').write_text('session.export\tstarted\nresult\tfinished\n')
        if case=='lock': (root/'.installer.lock').mkdir()
    env,callfile=environment(directory)
    if host=='bash' and os.name=='nt': env['PATH']=str(TOOLS)+os.pathsep+env['PATH']
    if case=='report-path-file': (root/'reports').write_text('preserve me')
    if case=='zip-failure':
        broken=directory/'broken-tools'; broken.mkdir()
        tool=broken/'zip'; tool.write_text('#!/usr/bin/env bash\nprintf partial > report.zip\nexit 1\n',newline='\n'); tool.chmod(0o755)
        env['PATH']=str(broken)+os.pathsep+env['PATH']
    p=subprocess.run(command(host,root,'support-report'),env=env,input=b'',capture_output=True,timeout=40)
    (directory/'output.txt').write_bytes(p.stdout+p.stderr)
    reports=list((root/'reports').glob('*.zip'))
    okay=p.returncode==(0 if case=='newest' else 1) and not callfile.read_text()
    okay &= (root/'.installer.lock').exists()==(case=='lock')
    okay &= len(reports)==(1 if case=='newest' else 0)
    if case=='report-path-file': okay &= (root/'reports').read_text()=='preserve me'
    if case=='zip-failure': okay &= not list((root/'reports').glob('.support.*'))
    if reports:
        with zipfile.ZipFile(reports[0]) as z:
            events=z.read('events.tsv').decode('utf-8-sig')
            okay &= 'session.check-base' in events and 'flash.super' not in events and 'session.export' not in events
    record=dict(host=host,case='export-'+case,ok=bool(okay),exit=p.returncode)
    print(json.dumps(record),flush=True)
    if not okay: print((p.stdout+p.stderr).decode(errors='replace'),flush=True)
    return record

cases=('normal','missing-super','missing-boot','corrupt-super','verify-corrupt','bad-tool','no-space',
       'locked','fastbootd','wrong-phone','no-phone','slot-b','stock','write-failed','erase-failed','gpt-failed','cancel-gpt','clean-success','cancel',
       'restore-success','restore-noop','update-success','verify-success','base-success')
with ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(lambda pair:run(*pair),[(h,c) for h in HOSTS for c in cases]))
    results+=list(pool.map(lambda pair:run_export(*pair),[(h,c) for h in HOSTS for c in ('empty','invalid-header','oversize','newest','lock','report-path-file')]+[('bash','zip-failure')]))
if os.name=='nt': results += [run_interrupt(False),run_interrupt(True)]
(WORK/'results.json').write_text(json.dumps(results,indent=2))
print('Readiness results: '+str(WORK/'results.json'))
sys.exit(0 if all(x['ok'] for x in results) else 1)
