# Xiaomi 13 (fuxi) super resize, 9 GiB <-> 11 GiB.
# Devine Machinery.
# Geometry matches the published fuxi ColorOS installer: sector 4096,
# entries 32/33 start 854080 and entries 31/32 start 751680.
# Requires Windows PowerShell 5.1. Run RESIZE.bat, not this file from a zip.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('expand', 'restore', 'check', 'rescue')]
    [string]$Mode = 'expand',
    [string]$Installer,
    [string]$Twrp,
    [string]$Vbmeta,
    [string]$VbmetaSystem,
    [string]$AdbPath,
    [string]$FastbootPath,
    [string]$Backup,
    [switch]$Erase,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
if ($Help) {
    Write-Host 'Fuxi super resize 1.0 — Xiaomi 13 (fuxi)'
    Write-Host 'Usage: RESIZE.bat [expand|restore|check|rescue] [-Backup path] [-Erase]'
    Write-Host 'Default mode: expand. Type YES to confirm any destructive operation.'
    Write-Host 'Resize does not flash super.img. The phone remains in fastboot.'
    exit 0
}
$StockBytes = [uint64]9663676416
$ExpandedBytes = [uint64]11811160064
$Root = $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }
$script:ExitCode = 1
$script:Serial = ''
$script:Slot = ''
$script:Transport = ''
$script:Phase = 'start'
$script:BackupPath = ''
$script:BackupHash = ''
$script:GptChanged = $false
$script:ToolExit = 0
$script:AdbRestarted = $false
$script:TempScript = ''
$script:LogPath = ''
$script:LockPath = ''

function Protect-Text([string]$Message) {
    if ($script:Serial) { return $Message.Replace($script:Serial, '<device>') }
    return $Message
}

function Write-Log([string]$Message) {
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + (Protect-Text $Message)
    if ($script:LogPath) {
        [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    }
    Write-Host $line
}

function Write-Detail([string]$Message) {
    if (-not $script:LogPath) { return }
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + (Protect-Text $Message)
    [IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding $false))
}

function Fail([string]$Message) { throw $Message }

function ConvertTo-NativeArgument([string]$Value) {
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-Tool([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 120, [switch]$Quiet, [switch]$AllowFail) {
    $script:ToolExit = -1
    Write-Detail ('> ' + $Executable + ' ' + ($Arguments -join ' '))
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $process.StartInfo.StandardOutputEncoding = $utf8
    $process.StartInfo.StandardErrorEncoding = $utf8
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextBeat = 20
    try {
        if (-not $process.Start()) { Fail "Could not start $Executable" }
        $stdout = $process.StandardOutput.ReadLineAsync()
        $stderr = $process.StandardError.ReadLineAsync()
        while ($null -ne $stdout -or $null -ne $stderr -or -not $process.HasExited) {
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                Fail "Timed out after ${TimeoutSeconds}s: $([IO.Path]::GetFileName($Executable))"
            }
            if ($null -ne $stdout -and $stdout.IsCompleted) {
                $line = $stdout.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdout = $null }
                else {
                    $lines.Add($line)
                    Write-Detail $line
                    $stdout = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $stderr -and $stderr.IsCompleted) {
                $line = $stderr.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderr = $null }
                else {
                    $lines.Add($line)
                    Write-Detail $line
                    $stderr = $process.StandardError.ReadLineAsync()
                }
            }
            if (-not $Quiet -and $timer.Elapsed.TotalSeconds -ge $nextBeat) {
                Write-Host ("  waiting {0}s, phase {1}" -f [int]$timer.Elapsed.TotalSeconds, $script:Phase)
                $nextBeat += 20
            }
            Start-Sleep -Milliseconds 30
        }
        $process.WaitForExit()
        $script:ToolExit = $process.ExitCode
        if ($process.ExitCode -ne 0 -and -not $AllowFail) {
            $tail = @($lines | Select-Object -Last 12) -join ' | '
            Fail "$([IO.Path]::GetFileName($Executable)) exited with code $($process.ExitCode). $tail"
        }
        return ,$lines.ToArray()
    } finally {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        } catch {}
        $process.Dispose()
    }
}

function Invoke-Probe([string]$Executable, [string[]]$Arguments) {
    $last = $null
    for ($try = 1; $try -le 3; $try++) {
        try { return Invoke-Tool $Executable $Arguments -TimeoutSeconds 20 -Quiet }
        catch {
            $last = $_
            $text = $_.Exception.Message
            if ($text -notmatch 'not found|no devices|offline|closed|Timed out|Status read failed|protocol fault') { throw }
            Start-Sleep -Seconds (2 * $try)
        }
    }
    throw $last
}

function Read-Yes([string]$Prompt) {
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Yellow
    Write-Host 'Type YES in uppercase. Any other input cancels the operation.'
    try { $answer = Read-Host 'Confirmation' } catch { return $false }
    return ($answer -ceq 'YES')
}

function Add-UniquePath([System.Collections.Generic.List[string]]$List, [string]$Path) {
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $full = (Resolve-Path -LiteralPath $Path).Path
    if (-not $List.Contains($full)) { [void]$List.Add($full) }
}

function Get-SearchRoots {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    Add-UniquePath $roots $Installer
    if (-not $Installer) {
        Add-UniquePath $roots $Root
        Add-UniquePath $roots (Split-Path -Parent $Root)
        Add-UniquePath $roots (Get-Location).Path
    }
    return ,$roots.ToArray()
}

function Resolve-FirstFile([string]$Explicit, [string[]]$Relative, [string]$CommandName) {
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { Fail "File not found: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }
    foreach ($base in @(Get-SearchRoots)) {
        foreach ($rel in $Relative) {
            $candidate = Join-Path $base $rel
            if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
    }
    if ($CommandName) {
        $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }
    return ''
}

function Resolve-TwrpImage {
    if ($Twrp) {
        if (-not (Test-Path -LiteralPath $Twrp)) { Fail "TWRP not found: $Twrp" }
        return (Resolve-Path -LiteralPath $Twrp).Path
    }
    $hits = New-Object 'System.Collections.Generic.List[string]'
    foreach ($base in @(Get-SearchRoots)) {
        $tools = Join-Path $base 'tools'
        if (-not (Test-Path -LiteralPath $tools)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $tools -Filter '*.img' -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -match 'twrp|TWRP|fuxi') { [void]$hits.Add($file.FullName) }
        }
    }
    $unique = @($hits | Select-Object -Unique)
    if ($unique.Count -eq 1) { return $unique[0] }
    if ($unique.Count -gt 1) {
        Fail ("Multiple TWRP images found. Specify -Twrp.`n" + ($unique -join "`n"))
    }
    return ''
}

function Resolve-Bundle {
    $script:Adb = Resolve-FirstFile $AdbPath @(
        'bin\platform-tools-windows\adb.exe',
        'platform-tools\adb.exe',
        'adb.exe'
    ) 'adb.exe'
    $script:Fastboot = Resolve-FirstFile $FastbootPath @(
        'bin\platform-tools-windows\fastboot.exe',
        'platform-tools\fastboot.exe',
        'fastboot.exe'
    ) 'fastboot.exe'
    $script:TwrpImage = Resolve-TwrpImage
    $script:VbmetaImage = Resolve-FirstFile $Vbmeta @('images\vbmeta.img') ''
    $script:VbmetaSystemImage = Resolve-FirstFile $VbmetaSystem @('images\vbmeta_system.img') ''
}

function Get-FastbootSerials([switch]$Soft) {
    $found = @()
    try {
        $lines = @(Invoke-Tool $script:Fastboot @('devices') -TimeoutSeconds 20 -Quiet -AllowFail)
    } catch {
        if ($Soft) { return ,@() }
        throw
    }
    if ($script:ToolExit -ne 0) {
        if ($Soft) { return ,@() }
        Fail 'fastboot devices failed.'
    }
    foreach ($line in $lines) {
        if (-not $line) { continue }
        if ($line -match '^(\S+)\s+fastboot\s*$') { $found += $Matches[1] }
        elseif ($line.Trim()) {
            if ($Soft) { return ,@() }
            Fail "Unexpected fastboot devices output: $line"
        }
    }
    return ,$found
}

function Get-AdbRows([switch]$Soft) {
    $rows = @()
    try {
        $lines = @(Invoke-Tool $script:Adb @('devices') -TimeoutSeconds 20 -Quiet -AllowFail)
    } catch {
        if ($Soft) { return ,@() }
        throw
    }
    if ($script:ToolExit -ne 0) {
        if ($Soft) { return ,@() }
        Fail 'adb devices failed.'
    }
    foreach ($line in $lines) {
        if (-not $line -or $line -match '^\s*$' -or $line -match '^List of devices attached\s*$' -or $line -match '^\* daemon') { continue }
        if ($line -match '^(\S+)\s+(device|recovery|offline|unauthorized|sideload)\s*$') {
            $rows += ($Matches[1] + ' ' + $Matches[2])
        } else {
            if ($Soft) { return ,@() }
            Fail "Unexpected adb devices output: $line"
        }
    }
    return ,$rows
}

function Get-FastbootVar([string]$Name) {
    $lines = @(Invoke-Probe $script:Fastboot @('-s', $script:Serial, 'getvar', $Name))
    $pattern = '(?i)^(?:\(bootloader\)\s+|bootloader:\s+)?' + [regex]::Escape($Name) + '\s*:\s*(\S+)\s*$'
    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        if ($line -match $pattern) { [void]$values.Add($Matches[1].ToLowerInvariant()) }
    }
    $unique = @($values | Select-Object -Unique)
    if ($unique.Count -ne 1) {
        Fail ("Could not read '$Name' unambiguously. Output: " + ($lines -join ' | '))
    }
    return [string]$unique[0]
}

function Convert-PartitionBytes([string]$Raw) {
    $text = $Raw.ToLowerInvariant()
    if ($text -match '^0x([0-9a-f]+)$') {
        return [uint64]::Parse($Matches[1], [Globalization.NumberStyles]::AllowHexSpecifier)
    }
    if ($text -match '^[0-9]+$') { return [uint64]$text }
    Fail "Unrecognized partition size: $Raw"
}

function Get-SuperBytes { return Convert-PartitionBytes (Get-FastbootVar 'partition-size:super') }

function Get-SizeLabel([uint64]$Bytes) {
    if ($Bytes -eq $StockBytes) { return '9 GiB' }
    if ($Bytes -eq $ExpandedBytes) { return '11 GiB' }
    return ("{0} bytes" -f $Bytes)
}

function Assert-Bootloader {
    $product = Get-FastbootVar 'product'
    if ($product -ne 'fuxi') { Fail "Connected device is not Xiaomi 13 fuxi (product=$product). Nothing was written." }
    $slot = (Get-FastbootVar 'current-slot') -replace '^_', ''
    if ($slot -ne 'a' -and $slot -ne 'b') { Fail "Unknown current slot '$slot'." }
    $script:Slot = $slot
    if ((Get-FastbootVar 'unlocked') -ne 'yes') { Fail 'The bootloader is locked. This script does not unlock it.' }
    if ((Get-FastbootVar 'is-userspace') -ne 'no') { Fail 'Bootloader fastboot is required. Fastbootd and unknown modes are refused.' }
}

function Read-AdbProp([string]$Name) {
    $lines = @(Invoke-Tool $script:Adb @('-s', $script:Serial, 'shell', 'getprop', $Name) -TimeoutSeconds 30 -Quiet)
    return (($lines -join '')).Trim()
}

function Assert-RecoveryIdentity {
    $product = Read-AdbProp 'ro.product.device'
    if ($product -ne 'fuxi') { Fail "Recovery reports '$product', not fuxi. GPT was not changed." }
    if ((Read-AdbProp 'sys.boot_completed') -eq '1') { Fail 'Android is running, not recovery. GPT was not changed.' }
}

function Connect-Phone {
    if (-not $script:Adb -or -not (Test-Path -LiteralPath $script:Adb)) { Fail 'adb.exe was not found. Keep this script next to the installer or specify -AdbPath.' }
    if (-not $script:Fastboot -or -not (Test-Path -LiteralPath $script:Fastboot)) { Fail 'fastboot.exe was not found. Keep this script next to the installer or specify -FastbootPath.' }
    [void](Invoke-Tool $script:Adb @('start-server') -TimeoutSeconds 20 -Quiet)
    $fastboot = @(Get-FastbootSerials)
    $adb = @(Get-AdbRows)
    $usable = @($adb | Where-Object { $_ -match ' (device|recovery)$' })
    if ($fastboot.Count -gt 1 -or $usable.Count -gt 1) { Fail 'Connect only one phone.' }
    if ($fastboot.Count -eq 1 -and $usable.Count -ge 1) { Fail 'The phone appears in both fastboot and ADB. Use only one transport.' }
    if ($fastboot.Count -eq 1) {
        $script:Serial = [string]$fastboot[0]
        $script:Transport = 'fastboot'
        return
    }
    if ($usable.Count -eq 1) {
        $parts = $usable[0] -split ' '
        $script:Serial = $parts[0]
        if ($parts[1] -eq 'recovery') { $script:Transport = 'recovery' }
        else {
            $booted = Read-AdbProp 'sys.boot_completed'
            $twrp = Read-AdbProp 'ro.twrp.version'
            $modeProp = Read-AdbProp 'ro.boot.mode'
            if ($booted -eq '1') { $script:Transport = 'android' }
            elseif ($twrp -or $modeProp -eq 'recovery') { $script:Transport = 'recovery' }
            else { $script:Transport = 'android' }
        }
        return
    }
    if (@($adb | Where-Object { $_ -match ' unauthorized$' }).Count -gt 0) {
        Fail 'Authorize USB debugging on the phone, then run this script again.'
    }
    Fail 'Phone not found. For fastboot, hold Power and Volume Down. Connect the cable directly to the computer.'
}

function Restart-AdbOnce {
    if ($script:AdbRestarted) { return }
    $script:AdbRestarted = $true
    Write-Log 'ADB is offline. Restarting the ADB server once.'
    try { [void](Invoke-Tool $script:Adb @('kill-server') -TimeoutSeconds 15 -AllowFail -Quiet) } catch {}
    try { [void](Invoke-Tool $script:Adb @('start-server') -TimeoutSeconds 20 -Quiet) } catch {}
}

function Wait-Transport([int]$Seconds) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $sawGone = $false
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        $adb = @(Get-AdbRows -Soft)
        $mine = @($adb | Where-Object { $_.StartsWith($script:Serial + ' ') })
        if ($mine.Count -eq 1) {
            $state = ($mine[0] -split ' ')[1]
            if ($state -eq 'device' -or $state -eq 'recovery') { return 'adb' }
            if ($state -eq 'unauthorized') { Write-Host 'Authorize debugging on the phone screen.' }
            if ($state -eq 'offline') { Restart-AdbOnce }
        }
        $fastboot = @(Get-FastbootSerials -Soft)
        if ($fastboot.Count -eq 0) { $sawGone = $true }
        elseif ($sawGone -and ($fastboot -contains $script:Serial) -and $timer.Elapsed.TotalSeconds -gt 8) { return 'fastboot' }
        elseif (-not $sawGone -and ($fastboot -contains $script:Serial) -and $timer.Elapsed.TotalSeconds -gt 15) { return 'fastboot' }
        Start-Sleep -Seconds 1
    }
    return 'timeout'
}

function Send-Fastboot([string[]]$Arguments, [int]$Timeout) {
    Write-Detail ('fastboot ' + ($Arguments -join ' '))
    [void](Invoke-Tool $script:Fastboot (@('-s', $script:Serial) + $Arguments) -TimeoutSeconds $Timeout)
}

function Assert-ImageFits([string]$Partition, [string]$Image) {
    $capacity = Convert-PartitionBytes (Get-FastbootVar "partition-size:$Partition")
    $length = [uint64](Get-Item -LiteralPath $Image).Length
    if ($length -le 0) { Fail "Empty file: $Image" }
    if ($length -gt $capacity) { Fail "Image does not fit in ${Partition}: $length bytes exceeds $capacity bytes." }
}

function Write-BothSlots([string]$BaseName, [string]$Image, [string[]]$Prefix, [int]$Timeout) {
    foreach ($slotName in @('a', 'b')) { Assert-ImageFits ($BaseName + '_' + $slotName) $Image }
    foreach ($slotName in @('a', 'b')) {
        $part = $BaseName + '_' + $slotName
        Write-Log ("Flashing $part")
        Send-Fastboot (@($Prefix) + @('flash', $part, $Image)) $Timeout
        Start-Sleep -Seconds 1
    }
}

function Enter-Recovery {
    [void](Invoke-Tool $script:Adb @('start-server') -TimeoutSeconds 20 -Quiet)
    for ($try = 1; $try -le 3; $try++) {
        Write-Log ("Entering TWRP, attempt $try of 3.")
        try { Send-Fastboot @('reboot', 'recovery') 40 } catch { Write-Log 'reboot recovery was not accepted.' }
        $landed = Wait-Transport 90
        if ($landed -eq 'adb') { return }
        if ($landed -eq 'timeout') {
            Write-Log 'The phone has not appeared yet. Waiting longer without another reboot.'
            if ((Wait-Transport 60) -eq 'adb') { return }
            continue
        }
        Write-Log 'The phone returned to fastboot. Trying oem reboot-recovery.'
        try { Send-Fastboot @('oem', 'reboot-recovery') 40 } catch { Write-Log 'oem reboot-recovery was not accepted.' }
        if ((Wait-Transport 90) -eq 'adb') { return }
    }
    Fail 'The phone did not appear in TWRP over ADB. If fastboot is shown, hold Volume Up and briefly press Power, wait for TWRP, then run this script again. Rerunning from TWRP does not reflash recovery. Do not boot Android.'
}

function Send-RecoveryScript {
    $source = Join-Path $Root 'prepare-super.sh'
    if (-not (Test-Path -LiteralPath $source)) { Fail 'prepare-super.sh is missing next to this script.' }
    $text = [IO.File]::ReadAllText($source).Replace("`r", '')
    if ($text -notmatch 'FUXI_RESULT=applied') { Fail 'prepare-super.sh is damaged.' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('fuxi-prepare-' + [guid]::NewGuid().ToString('N') + '.sh')
    [IO.File]::WriteAllText($temp, $text, (New-Object System.Text.UTF8Encoding $false))
    $script:TempScript = $temp
    Write-Log 'Sending the partition script to recovery.'
    [void](Invoke-Tool $script:Adb @('-s', $script:Serial, 'push', $temp, '/tmp/prepare-super.sh') -TimeoutSeconds 120)
}

function Invoke-Recovery([string]$Action, [string]$Confirm, [string]$Hash) {
    $command = 'sh /tmp/prepare-super.sh ' + $Action
    if ($Confirm) { $command = "FUXI_CONFIRM=$Confirm FUXI_BACKUP_SHA256=$Hash $command" }
    try {
        return Invoke-Tool $script:Adb @('-s', $script:Serial, 'shell', $command) -TimeoutSeconds 180
    } catch {
        if ($_.Exception.Message -match 'FUXI_RESULT=rollback') {
            Fail 'GPT verification failed and recovery restored the backup. Run the script again. Do not boot Android.'
        }
        throw
    }
}

function Get-Marker([string[]]$Lines, [string]$Name) {
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=([A-Za-z0-9-]+)\s*$'
    $matched = [regex]::Matches(($Lines -join "`n"), $pattern)
    if ($matched.Count -lt 1) { return '' }
    return $matched[$matched.Count - 1].Groups[1].Value
}

function Save-GptBackup {
    $script:Phase = 'audit'
    Write-Log 'Reading GPT and saving a backup on the computer. No table write has occurred.'
    $lines = @(Invoke-Recovery 'audit' '' '')
    if ((Get-Marker $lines 'FUXI_RESULT') -ne 'audit') {
        Fail ("GPT audit did not complete.`n" + (($lines | Select-Object -Last 20) -join "`n"))
    }
    $layout = Get-Marker $lines 'FUXI_LAYOUT'
    if ($layout -ne 'stock' -and $layout -ne 'expanded') { Fail 'Recovery did not report a supported super boundary.' }
    $remote = @(Invoke-Tool $script:Adb @('-s', $script:Serial, 'shell', 'sha256sum /tmp/fuxi-gpt-before.bin') -TimeoutSeconds 60)
    $joined = ($remote -join "`n")
    if ($joined -notmatch '(?m)^([0-9a-fA-F]{64})\s+/tmp/fuxi-gpt-before\.bin\s*$') {
        Fail "Could not read the GPT backup checksum: $joined"
    }
    $hash = $Matches[1].ToLowerInvariant()
    $backupDir = Join-Path $Root 'backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $path = Join-Path $backupDir ('fuxi-gpt-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bin')
    [void](Invoke-Tool $script:Adb @('-s', $script:Serial, 'pull', '/tmp/fuxi-gpt-before.bin', $path) -TimeoutSeconds 120)
    if (-not (Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -le 0) {
        Fail 'The GPT backup was not saved on the computer.'
    }
    $local = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($local -ne $hash) { Fail 'The computer backup checksum does not match the phone. GPT was not changed.' }
    [IO.File]::WriteAllText($path + '.sha256', $hash + "`n", (New-Object System.Text.UTF8Encoding $false))
    $script:BackupPath = $path
    $script:BackupHash = $hash
    $script:Layout = $layout
    Write-Log "GPT backup saved: $path"
    Write-Log ("Recovery boundary: " + $(if ($layout -eq 'stock') { '9 GiB' } else { '11 GiB' }))
}

function Return-ToFastboot {
    $script:Phase = 'verify'
    Write-Log 'Returning the phone to fastboot and checking super size.'
    try { [void](Invoke-Tool $script:Adb @('-s', $script:Serial, 'reboot', 'bootloader') -TimeoutSeconds 40) } catch {
        Write-Log 'adb reboot bootloader was not accepted. Waiting for fastboot.'
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 120) {
        $fastboot = @(Get-FastbootSerials -Soft)
        if ($fastboot -contains $script:Serial) {
            Assert-Bootloader
            return
        }
        Start-Sleep -Seconds 1
    }
    Fail 'The phone did not return to fastboot. If TWRP is open, do not boot Android; run this script again.'
}

function Clear-Userdata {
    $script:Phase = 'erase'
    Write-Log 'Erasing userdata and metadata. This may take several minutes.'
    Send-Fastboot @('erase', 'userdata') 1200
    Send-Fastboot @('erase', 'metadata') 180
    Write-Log 'userdata and metadata were erased.'
}

function Assert-RecoveryBundle {
    if (-not $script:TwrpImage) { Fail 'TWRP was not found. Specify -Twrp or unpack the installer and provide -Installer.' }
    if (-not $script:VbmetaImage -or -not $script:VbmetaSystemImage) {
        Fail 'images\vbmeta.img and images\vbmeta_system.img are missing. They are required to boot TWRP on both slots.'
    }
    foreach ($image in @($script:TwrpImage, $script:VbmetaImage, $script:VbmetaSystemImage)) {
        $length = (Get-Item -LiteralPath $image).Length
        if ($length -le 0 -or $length -gt 268435456) { Fail "Suspicious image size: $image" }
    }
}

function Enable-Recovery {
    $script:Phase = 'flash-recovery'
    Assert-RecoveryBundle
    Write-Log 'Checking that images fit both slots. Nothing is written before this check.'
    foreach ($slotName in @('a', 'b')) {
        Assert-ImageFits ('vbmeta_' + $slotName) $script:VbmetaImage
        Assert-ImageFits ('vbmeta_system_' + $slotName) $script:VbmetaSystemImage
        Assert-ImageFits ('recovery_' + $slotName) $script:TwrpImage
    }
    $prefix = @('--disable-verity', '--disable-verification')
    Write-BothSlots 'vbmeta' $script:VbmetaImage $prefix 180
    Write-BothSlots 'vbmeta_system' $script:VbmetaSystemImage $prefix 180
    Write-BothSlots 'recovery' $script:TwrpImage @() 180
    Enter-Recovery
    Assert-RecoveryIdentity
}

function Enter-Lock {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $Root }
    $dir = Join-Path $base 'DevineMachinery\FuxiResize'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:LockPath = Join-Path $dir 'run.lock'
    if (Test-Path -LiteralPath $script:LockPath) {
        $old = @(Get-Content -LiteralPath $script:LockPath -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($old -match '^\d+$') {
            $alive = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
            if ($alive -and -not $alive.HasExited) { Fail 'Another resize process is running. Wait for it to finish.' }
        }
    }
    [IO.File]::WriteAllText($script:LockPath, "$PID`n", (New-Object System.Text.UTF8Encoding $false))
}

function Exit-Lock {
    try {
        if ($script:LockPath -and (Test-Path -LiteralPath $script:LockPath)) {
            $old = @(Get-Content -LiteralPath $script:LockPath -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($old -eq "$PID") { Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue }
        }
        if ($script:TempScript -and (Test-Path -LiteralPath $script:TempScript)) {
            Remove-Item -LiteralPath $script:TempScript -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

function Get-TargetBytes {
    if ($Mode -eq 'restore') { return $StockBytes }
    return $ExpandedBytes
}

function Show-FastbootState([uint64]$Bytes) {
    Write-Log ("Slot $($script:Slot), super " + (Get-SizeLabel $Bytes) + '.')
}

. "$PSScriptRoot/../scripts/safety.ps1"

try {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
    $logDir = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $script:LogPath = Join-Path $logDir ('resize-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    Write-Log 'Fuxi super resize 1.0 — Devine Machinery'
    Write-Log 'Xiaomi 13 (fuxi) only. Super boundary: 9 GiB <-> 11 GiB. This script does not flash super.img.'
    Write-Log "Log: $($script:LogPath)"
    Enter-Lock
    Resolve-Bundle
    if ($Mode -eq 'rescue' -and -not $Backup) { Fail 'Rescue mode requires -Backup and a path to fuxi-gpt-....bin.' }
    if ($Mode -eq 'rescue' -and -not (Test-Path -LiteralPath $Backup)) { Fail "GPT backup not found: $Backup" }

    Connect-Phone
    Write-Log 'Phone found. Its serial number is not written to the log.'

    if ($Mode -eq 'check') {
        $script:Phase = 'check'
        if ($script:Transport -eq 'fastboot') {
            Assert-Bootloader
            Show-FastbootState (Get-SuperBytes)
            Write-Log 'This check only reads the size. GPT was not changed.'
            $script:ExitCode = 0
            exit 0
        }
        if ($script:Transport -eq 'recovery') {
            Assert-RecoveryIdentity
            Send-RecoveryScript
            Save-GptBackup
            Write-Log 'Audit complete. The phone remains in TWRP; GPT was not changed.'
            $script:ExitCode = 0
            exit 0
        }
        Fail 'Check mode does not reboot Android. Enter fastboot or TWRP, then run the check again.'
    }

    $startedBytes = [uint64]0
    $knownStart = $false
    $resizeMode = ($Mode -eq 'expand' -or $Mode -eq 'restore')
    if ($script:Transport -eq 'android') {
        $product = Read-AdbProp 'ro.product.device'
        if ($product -ne 'fuxi') { Fail "ADB reports '$product', not fuxi." }
        Write-Log 'The phone is running Android. After confirmation it will enter fastboot.'
    } elseif ($script:Transport -eq 'fastboot') {
        Assert-Bootloader
        $startedBytes = Get-SuperBytes
        $knownStart = $true
        Show-FastbootState $startedBytes
        if ($resizeMode -and $startedBytes -ne $StockBytes -and $startedBytes -ne $ExpandedBytes) {
            Fail ("Super size " + (Get-SizeLabel $startedBytes) + ' is neither supported 9 GiB nor 11 GiB. Nothing was written.')
        }
        if ($resizeMode -and $startedBytes -eq (Get-TargetBytes) -and -not $Erase) {
            Write-Log 'The requested boundary is already set. No data was erased and no partitions were flashed.'
            $script:ExitCode = 0
            exit 0
        }
        if ($resizeMode -and $startedBytes -eq (Get-TargetBytes) -and $Erase) {
            if (-not (Read-Yes 'The boundary is already correct. Erase userdata and metadata without changing GPT?')) {
                Write-Log 'Cancelled before erasing.'
                $script:ExitCode = 2
                exit 2
            }
            Clear-Userdata
            Write-Log 'Erase complete. The phone remains in fastboot. Do not boot Android until you flash the system.'
            $script:ExitCode = 0
            exit 0
        }
    } else {
        Assert-RecoveryIdentity
        Write-Log 'TWRP is already running. Recovery and vbmeta will not be flashed again.'
    }

    $targetLabel = if ($Mode -eq 'restore') { '9 GiB' } else { '11 GiB' }
    if ($Mode -eq 'rescue') {
        $plan = 'Rescue mode replaces the current GPT with a saved backup. It does not erase data. If TWRP is not already open, vbmeta and recovery will be flashed to both slots. Do not boot Android until the super size has been verified.'
    } else {
        $plan = "Operation: change the physical super partition to $targetLabel. If the boundary moves, userdata and metadata will be erased; back up important files first. If TWRP is not running, vbmeta, vbmeta_system and recovery will be flashed to slots A and B. Cancelling after those writes leaves the phone in TWRP without changing GPT. After a boundary change, the current system will not boot: flash the ColorOS super for 11 GiB or an official fuxi ROM for 9 GiB. The phone will remain in fastboot."
    }
    if (-not (Read-Yes $plan)) {
        Write-Log 'Cancelled before writing.'
        $script:ExitCode = 2
        exit 2
    }

    Confirm-BootloaderRestart
    if ($script:Transport -eq 'android') {
        $script:Phase = 'reboot-bootloader'
        [void](Invoke-Tool $script:Adb @('-s', $script:Serial, 'reboot', 'bootloader') -TimeoutSeconds 40)
        $landed = Wait-Transport 90
        if ($landed -ne 'fastboot') { Fail 'The phone did not enter fastboot.' }
        Assert-Bootloader
        $script:Transport = 'fastboot'
        $startedBytes = Get-SuperBytes
        $knownStart = $true
        Show-FastbootState $startedBytes
        if ($resizeMode -and $startedBytes -ne $StockBytes -and $startedBytes -ne $ExpandedBytes) {
            Fail ("Super size " + (Get-SizeLabel $startedBytes) + ' is neither supported 9 GiB nor 11 GiB. Recovery was not flashed.')
        }
        if ($resizeMode -and $startedBytes -eq (Get-TargetBytes) -and -not $Erase) {
            Write-Log 'The requested boundary is already set. Recovery was not flashed and data was not erased.'
            $script:ExitCode = 0
            exit 0
        }
    }
    if ($script:Transport -eq 'fastboot') { Enable-Recovery }
    else { Assert-RecoveryIdentity }

    Send-RecoveryScript
    if ($Mode -eq 'rescue') {
        $script:Phase = 'rescue'
        $rescuePath = (Resolve-Path -LiteralPath $Backup).Path
        $hash = (Get-FileHash -LiteralPath $rescuePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [void](Invoke-Tool $script:Adb @('-s', $script:Serial, 'push', $rescuePath, '/tmp/fuxi-gpt-restore.bin') -TimeoutSeconds 120)
        if (-not (Read-Yes "Load the saved GPT from $rescuePath? The current table will be replaced with this backup.")) {
            Write-Log 'Cancelled before loading the GPT backup. The table was not changed.'
            $script:ExitCode = 2
            exit 2
        }
        $lines = @(Invoke-Recovery 'load-backup' 'LOAD_GPT_BACKUP' $hash)
        if ((Get-Marker $lines 'FUXI_RESULT') -ne 'backup-loaded') {
            Fail ("The GPT backup could not be loaded.`n" + (($lines | Select-Object -Last 20) -join "`n"))
        }
        Return-ToFastboot
        Show-FastbootState (Get-SuperBytes)
        Write-Log 'GPT backup loaded. This script did not erase data. Do not boot Android until super size matches the ROM you will install.'
        $script:ExitCode = 0
        exit 0
    }
    Save-GptBackup
    if ($knownStart -and $Mode -eq 'expand' -and $startedBytes -eq $StockBytes -and $script:Layout -eq 'expanded') {
        Fail 'Fastboot reported 9 GiB but recovery reports 11 GiB. GPT state is inconsistent. Do not boot Android; save the log and GPT backup.'
    }
    if ($knownStart -and $Mode -eq 'restore' -and $startedBytes -eq $ExpandedBytes -and $script:Layout -eq 'stock') {
        Fail 'Fastboot reported 11 GiB but recovery reports 9 GiB. GPT state is inconsistent. Do not boot Android; save the log and GPT backup.'
    }

    $wantedLayout = if ($Mode -eq 'restore') { 'stock' } else { 'expanded' }
    $changed = $false
    if ($script:Layout -eq $wantedLayout) {
        Write-Log 'Recovery already sees the requested boundary. GPT will not be written again.'
    } else {
        $confirm = if ($Mode -eq 'restore') { 'RESTORE_STOCK_SUPER' } else { 'ERASE_AND_RESIZE' }
        $action = if ($Mode -eq 'restore') { 'restore' } else { 'apply' }
        if (-not (Read-Yes "GPT backup verified. Change the super boundary to $targetLabel? Userdata will then be erased.")) {
            Write-Log 'Cancelled before changing GPT. Recovery and vbmeta may already have been flashed, but the partition table was not changed. The phone remains in TWRP.'
            $script:ExitCode = 2
            exit 2
        }
        $script:Phase = 'gpt'
        Write-Log 'Changing the super and userdata boundary. Other partitions must remain unchanged.'
        $lines = @(Invoke-Recovery $action $confirm $script:BackupHash)
        $marker = Get-Marker $lines 'FUXI_RESULT'
        if ($marker -ne 'applied' -and $marker -ne 'restored') {
            Fail ("GPT change was not confirmed.`n" + (($lines | Select-Object -Last 20) -join "`n"))
        }
        $changed = $true
    }

    Return-ToFastboot
    $finalBytes = Get-SuperBytes
    $expected = Get-TargetBytes
    if ($finalBytes -ne $expected) {
        Fail ("After reboot, super is " + (Get-SizeLabel $finalBytes) + ", expected $targetLabel. Do not boot Android.")
    }
    if ($changed) { $script:GptChanged = $true }
    Show-FastbootState $finalBytes

    if ($changed -or $Erase) {
        Clear-Userdata
        if ($Mode -eq 'restore') {
            Write-Log 'Super is back to 9 GiB and data was erased. The phone is in fastboot. Flash an official fuxi ROM; do not boot the previous system.'
        } else {
            Write-Log 'Super is 11 GiB and data was erased. The phone is in fastboot. Now flash super with the ColorOS installer. Do not boot Android yet.'
        }
    } else {
        Write-Log 'The boundary was already correct, so data was not erased.'
        Write-Log 'If an earlier run moved the boundary but stopped before erasing, run RESIZE.bat expand -Erase and do not boot Android.'
    }
    $script:ExitCode = 0
    exit 0
} catch {
    $text = $_.Exception.Message
    Write-Host ''
    Write-Host ("Error: " + (Protect-Text $text)) -ForegroundColor Red
    Write-Host ("Phase: " + $script:Phase)
    if ($script:BackupPath) { Write-Host ("GPT backup: " + $script:BackupPath) }
    if ($script:GptChanged) {
        Write-Host 'The super boundary changed, but erasing may not have completed. Do not boot Android. Run RESIZE.bat again with -Erase.' -ForegroundColor Yellow
    } else {
        Write-Host 'If GPT may have changed, do not boot Android. Retry from TWRP or use RESIZE.bat rescue -Backup <file>.' -ForegroundColor Yellow
    }
    if ($script:LogPath) { Write-Host ("Log: " + $script:LogPath) }
    $script:ExitCode = 1
    exit 1
} finally {
    Exit-Lock
}
