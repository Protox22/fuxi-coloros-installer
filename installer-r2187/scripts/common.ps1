Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    # A .bat launched from PowerShell 7 can inherit its incompatible module paths.
    Import-Module "$PSHOME/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1" -Force
}
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

. "$PSScriptRoot/language.ps1"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $Root
$Images = Join-Path $Root 'images'
$Fastboot = Join-Path $Root 'bin\platform-tools-windows\fastboot.exe'
$Adb = Join-Path $Root 'bin\platform-tools-windows\adb.exe'
$Zstd = Join-Path $Root 'bin\platform-tools-windows\zstd.exe'
$StockSuper = '0x240000000'
$ExpandedSuper = '0x2c0000000'
$Serial = ''
$SuperImage = $null
$SelectedBootImage = ''
$SessionLock = $null
$TranscriptStarted = $false
$DetailWriter = $null
$AllowedBootSlots = @('a')
$ExpectedBootSlot = ''
$CheckedBootSlot = ''
$SessionLog = ''
if (-not (Test-Path Variable:Compact)) { $Compact = $false }

. "$PSScriptRoot/status.ps1"

function Fail([string]$Message) { throw $Message }

function Show-ErrorHint([string]$Message) {
    Show-FailureState
    $key = switch -Regex ($Message) {
        'SHA-256|checksum|missing.*file|firmware.conf' { 'hintFiles'; break }
        'installer.lock' { 'hintLock'; break }
        'space|GiB free' { 'hintSpace'; break }
        'slot' { 'hintSlot'; break }
        'required tool|executable|not recognized' { 'hintTools'; break }
        'device|ADB|locked|permissions|Timed out' { 'hintUsb'; break }
        default { 'hintStopped' }
    }
    Write-Host (Get-Text $key) -ForegroundColor Yellow
    Write-Event 'error' $key
    if ($script:SessionLog) { Write-Host (Get-Text 'logPath' @($script:SessionLog)) }
}

function Write-Detail([string]$Message, [switch]$Quiet) {
    if ($script:Compact) {
        if ($null -ne $script:DetailWriter) { $script:DetailWriter.WriteLine($Message) }
    } elseif (-not $Quiet) { Write-Host $Message }
}

function Write-Step([string]$Message) {
    Write-Host "  > $Message" -ForegroundColor Cyan
}

function Read-Confirmation([string]$Detailed, [string]$Short) {
    $prompt = if ($script:Compact) { "  $Short" } else { $Detailed }
    while ($true) {
        $answer = Read-Host "$prompt [y/N]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $false }
        switch -Exact ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'n' { return $false }
            default { Write-Host (Get-Text 'invalidYesNo') -ForegroundColor Yellow }
        }
    }
}

function Verify-Payload([switch]$InstallerOnly, [switch]$DiagnosticsOnly) {
    Write-Event 'phase.verify' 'started'
    $required = @('scripts/status.ps1', 'scripts/status.sh', 'support-report.ps1', 'support-report.sh', 'FLASH.bat',  'super-resize/resize.ps1', 'super-resize/prepare-super.sh', 'START.sh',  'scripts/menu.ps1', 'scripts/menu.sh', 'scripts/language.ps1', 'scripts/language.sh', 'scripts/process.ps1', 'check-base.ps1', 'check-base.sh', 'flash.ps1', 'flash.sh', 'restore-super.ps1', 'restore-super.sh',
        'boot-variants.conf', 'BOOT_VARIANTS.json', 'images/boot-no-root.img', 'scripts/boot-variants.ps1', 'scripts/boot-variants.sh', 'scripts/safety.ps1', 'scripts/safety.sh', 'scripts/common.ps1', 'scripts/common.sh', 'scripts/builds.ps1', 'scripts/builds.sh', 'scripts/prepare-super.sh', 'images/recovery.img', 'images/super.img.zst',
        'images/vbmeta.img', 'images/vbmeta_system.img', 'tools/TWRP-FUXI-A17.img', 'bin/platform-tools-windows/adb.exe',
        'bin/platform-tools-windows/fastboot.exe', 'bin/platform-tools-windows/zstd.exe', 'bin/platform-tools-windows/AdbWinApi.dll',
        'bin/platform-tools-windows/AdbWinUsbApi.dll', 'bin/platform-tools-windows/NOTICE.txt',
        'bin/platform-tools-windows/source.properties', 'bin/platform-tools-windows/LICENSE-zstd.txt',
        'firmware.conf', 'prepare-payload.py', 'scripts/payload.py', 'PREPARE_PAYLOAD.bat')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $sumFile = Join-Path $Root 'SHA256SUMS.txt'
    $entries = @(Get-Content -LiteralPath $sumFile)
    $index = 0
    foreach ($line in $entries) {
        if ($line -notmatch '^([0-9a-fA-F]{64})  (?:\./)?([A-Za-z0-9_./-]+)$') { Fail "Invalid checksum entry: $line" }
        $expected = $Matches[1]
        $relative = $Matches[2]
        if ($relative.StartsWith('/') -or $relative.EndsWith('/') -or $relative.Contains('//') -or $relative -match '(^|/)\.\.?(/|$)' -or -not $seen.Add($relative)) {
            Fail "Unsafe or duplicate checksum path: $relative"
        }
        $path = Join-Path $Root $relative
        $prefix = $Root
        foreach ($part in $relative.Split('/')) {
            $prefix = Join-Path $prefix $part
            if (Test-Path -LiteralPath $prefix) {
                if ((Get-Item -LiteralPath $prefix -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail "Reparse point in checksum path: $relative" }
            }
        }
        if ($DiagnosticsOnly -and ($relative.StartsWith('images/') -or $relative.StartsWith('tools/'))) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($InstallerOnly -and ($relative.StartsWith('images/') -or $relative.StartsWith('tools/'))) { Write-Detail "OMITTED  $relative (installer-only check)"; continue }
            Fail "Required release file is missing: $relative"
        }
        $index++
        if ($Compact) { Write-Host ('  ' + (Get-Text 'checkingFile' @($index, $entries.Count, $relative))) }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) { Fail "SHA-256 mismatch: $relative" }
        Write-Detail "GOOD  $relative"
    }
    foreach ($relative in $required) {
        if (-not $seen.Contains($relative)) { Fail "Required checksum entry is missing: $relative" }
    }
    Read-FirmwareProfile
    foreach ($name in $script:ExtraImages) {
        if (-not $seen.Contains("images/$name.img")) { Fail "Required checksum entry is missing: images/$name.img" }
    }
}

function Read-FirmwareProfile {
    $config = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root 'firmware.conf')) {
        if ($line -cnotmatch '^([a-z][a-z0-9_]*)=([A-Za-z0-9._,-]*)$' -or $config.ContainsKey($Matches[1])) { Fail 'Invalid or duplicate firmware.conf entry.' }
        $config[$Matches[1]] = $Matches[2]
    }
    $keys = @('format', 'name', 'base_firmware', 'super_sparse_bytes', 'super_expanded_bytes', 'super_sha256', 'extra_images')
    if ($config.Count -ne $keys.Count) { Fail 'Unknown or missing firmware.conf keys.' }
    foreach ($key in $keys) { if (-not $config.ContainsKey($key)) { Fail "Missing firmware.conf key: $key" } }
    if ($config.format -cne '1' -or $config.super_expanded_bytes -cne '11811160064') { Fail 'Only the supported fuxi 11 GiB super profile is accepted.' }
    foreach ($key in @('name', 'base_firmware')) {
        if ($config[$key] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') { Fail "Invalid profile value: $key" }
    }
    if ($config.super_sparse_bytes -cnotmatch '^[1-9][0-9]{1,10}$' -or
        [int64]$config.super_sparse_bytes -lt 28 -or [int64]$config.super_sparse_bytes -gt 12884901888 -or
        $config.super_sha256 -cnotmatch '^[0-9a-f]{64}$') { Fail 'Invalid sparse image size or hash in firmware.conf.' }
    $script:ExtraImages = @()
    if ($config.extra_images) {
        foreach ($name in $config.extra_images.Split(',')) {
            if ($name -cnotin @('boot', 'init_boot', 'vendor_boot', 'dtbo') -or $script:ExtraImages -ccontains $name) { Fail "Unsupported or duplicate extra image: $name" }
            $script:ExtraImages += $name
        }
    }
    $script:RequiredFirmware = $config.base_firmware
    $script:FirmwareName = $config.name
    $script:SuperSparseBytes = [int64]$config.super_sparse_bytes
    $script:SuperSha256 = $config.super_sha256
}

function Start-Session([string]$Operation) {
    try {
        $script:SessionLock = [IO.File]::Open((Join-Path $Root '.installer.lock'), 'CreateNew', 'ReadWrite', 'Read')
    } catch { Fail 'Cannot acquire .installer.lock. Another operation is running, a stale lock remains, or the folder is not writable.' }
    $owner = [Text.Encoding]::UTF8.GetBytes("pid=$PID operation=$Operation`n")
    $script:SessionLock.Write($owner, 0, $owner.Length)
    $script:SessionLock.Flush()
    $logs = Join-Path $Root 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $log = Join-Path $logs ((Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-' + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-' + $Operation + '.log')
    $script:SessionLog = $log
    $script:EventFile = $log + '.events.tsv'
    Write-Event ('session.' + $Operation) 'started'
    if ($Compact) {
        $script:DetailWriter = New-Object IO.StreamWriter ($log + '.details.txt'), $false, (New-Object Text.UTF8Encoding $true)
        $script:DetailWriter.AutoFlush = $true
    }
    Start-Transcript -LiteralPath $log -NoClobber | Out-Null
    $script:TranscriptStarted = $true
    Write-Host (Get-Text 'logPath' @($log))
}

function Stop-Session {
    Write-Event 'result' $script:SessionOutcome
    if ($script:SuperImage) {
        # Delete only the exact temporary file and directory created by this process.
        try {
            if (Test-Path -LiteralPath $script:SuperImage) { Remove-Item -LiteralPath $script:SuperImage -ErrorAction Stop }
            Remove-Item -LiteralPath (Split-Path -Parent $script:SuperImage) -ErrorAction Stop
            Write-Host (Get-Text 'tempRemoved')
        } catch { Write-Warning "Temporary image cleanup failed: $script:SuperImage" }
        $script:SuperImage = $null
    }
    if ($script:TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {}; $script:TranscriptStarted = $false }
    if ($null -ne $script:DetailWriter) { $script:DetailWriter.Dispose(); $script:DetailWriter = $null }
    if ($null -ne $script:SessionLock) {
        $script:SessionLock.Dispose()
        $script:SessionLock = $null
        try { Remove-Item -LiteralPath (Join-Path $Root '.installer.lock') -ErrorAction Stop }
        catch { Write-Warning 'Could not remove the session lock. Check that no other installer operation is running before retrying.' }
    }
}

function Check-ExtraImages {
    foreach ($name in $script:ExtraImages) {
        $value = (Get-FastbootVar "partition-size:${name}_a") -replace '^0x', ''
        if ($value -notmatch '^[0-9a-f]{1,16}$' -or [Convert]::ToUInt64($value, 16) -lt (Get-Item -LiteralPath (Get-ExtraImagePath $name)).Length) {
            Fail "Extra image exceeds the physical partition size: ${name}_a"
        }
    }
}

function Check-RequiredImages([ValidateSet('a','b')][string]$Slot = 'a', [switch]$ForResize) {
    foreach ($name in @('recovery', 'vbmeta', 'vbmeta_system')) {
        $partition = "${name}_$Slot"
        $value = (Get-FastbootVar "partition-size:$partition") -replace '^0x', ''
        $image = if ($ForResize -and $name -eq 'recovery') { 'tools/TWRP-FUXI-A17.img' } else { Get-ExtraImagePath $name }
        $size = (Get-Item -LiteralPath $image).Length
        if ($value -notmatch '^[0-9a-f]{1,16}$' -or [Convert]::ToUInt64($value, 16) -lt $size) {
            Fail "Required image exceeds the physical partition size: $partition"
        }
    }
}

. "$PSScriptRoot/process.ps1"
. "$PSScriptRoot/safety.ps1"
. "$PSScriptRoot/boot-variants.ps1"

function Invoke-Fastboot([string[]]$Arguments) {
    Write-Step ('fastboot ' + ($Arguments[0..([Math]::Min(1, $Arguments.Count - 1))] -join ' '))
    Invoke-DeviceTool 'fastboot' $Arguments
}
function Invoke-Adb([string[]]$Arguments) {
    Invoke-DeviceTool 'adb' $Arguments
}

function Get-FastbootVar([string]$Name) {
    $output = (Invoke-Tool $Fastboot @('-s', $script:Serial, 'getvar', $Name) -Quiet) -join "`n"
    $pattern = '(?m)^(?:\(bootloader\)[ \t]*|bootloader:[ \t]*)?' + [regex]::Escape($Name) + ':[ \t]*(\S+)[ \t\r]*$'
    $found = [regex]::Matches($output, $pattern)
    if ($found.Count -ne 1) { Fail "Could not read a single fastboot variable '$Name'. Output: $output" }
    return $found[0].Groups[1].Value.ToLowerInvariant()
}

function Get-SuperSize {
    $value = (Get-FastbootVar 'partition-size:super') -replace '^0x', ''
    if ($value -notmatch '^[0-9a-f]{1,16}$') { Fail "Invalid super size: $value" }
    return '0x{0:x}' -f [Convert]::ToUInt64($value, 16)
}

function Get-FastbootDevices {
    foreach ($line in (Invoke-Tool $Fastboot @('devices') -Quiet)) {
        if ($line -match '^([^\s]+)\s+fastboot\s*$') { $Matches[1] }
        elseif ($line.Trim()) { Fail "Unexpected fastboot devices output: $line" }
    }
}

function Wait-Fastboot {
    Write-Detail 'Waiting for the selected device in bootloader fastboot...'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 120) {
        $devices = @(Get-FastbootDevices)
        if ($devices.Count -gt 1) { Fail 'Disconnect other fastboot devices.' }
        if ($devices.Count -eq 1 -and $devices[0] -eq $script:Serial) { return }
        Start-Sleep -Seconds 1
    }
    Fail 'Timed out waiting for the selected device in fastboot.'
}

function Wait-Adb {
    Write-Detail 'Waiting for the selected device in TWRP recovery...'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 180) {
        try { $state = ((Invoke-Tool $Adb @('-s', $script:Serial, 'get-state') -Quiet) -join '').Trim() }
        catch { $state = '' }
        if ($state -eq 'device' -or $state -eq 'recovery') { return }
        Start-Sleep -Seconds 1
    }
    Fail 'Timed out waiting for recovery ADB.'
}

function Connect-Device {
    Write-Event 'phase.device' 'started'
    [void](Invoke-Tool $Adb @('start-server') -Quiet)
    $devices = @(Get-FastbootDevices)
    $adbDevices = @(Get-AdbDevices)
    if ($devices.Count + $adbDevices.Count -ne 1) { Fail 'Connect exactly one device, in bootloader fastboot or authorized ADB.' }
    if ($devices.Count -eq 0) {
        if ($adbDevices[0] -notmatch '^(\S+)\s+(device|recovery)\s*$') { Fail 'Authorize ADB or enter bootloader fastboot manually.' }
        $script:Serial = $Matches[1]
        $product = ((Invoke-Adb @('shell', 'getprop', 'ro.product.device')) -join '').Trim()
        if ($product -ne 'fuxi') { Fail "Connected ADB device is not fuxi: $product" }
        Confirm-BootloaderRestart
        [void](Invoke-Adb @('reboot', 'bootloader'))
        Wait-Fastboot
    } else { $script:Serial = $devices[0] }
    Check-Bootloader
}

function Get-AdbDevices {
    foreach ($line in (Invoke-Tool $Adb @('devices') -Quiet)) {
        if ($line -match '^\S+\s+(device|recovery|offline|unauthorized|sideload)\s*$') { $line }
        elseif ($line -match '^List of devices attached\s*$|^\* daemon' -or -not $line.Trim()) { continue }
        else { Fail "Unexpected adb devices output (check USB permissions): $line" }
    }
}

function Check-Bootloader {
    if ((Get-FastbootVar 'product') -ne 'fuxi') { Fail 'Connected device is not Xiaomi 13 fuxi.' }
    $slot = (Get-FastbootVar 'current-slot') -replace '^_', ''
    if ($slot -notin $script:AllowedBootSlots) { Fail "Unsupported active slot '$slot'. Allowed: $($script:AllowedBootSlots -join ', ')." }
    if ($script:ExpectedBootSlot -and $slot -ne $script:ExpectedBootSlot) { Fail "Active slot changed unexpectedly: expected $script:ExpectedBootSlot, got $slot." }
    $script:CheckedBootSlot = $slot
    if ((Get-FastbootVar 'unlocked') -ne 'yes') { Fail 'The bootloader is locked.' }
    if ((Get-FastbootVar 'is-userspace') -ne 'no') { Fail 'Bootloader fastboot is required. Unknown mode and fastbootd are refused.' }
}

function Start-ResizeRecovery {
    Write-Step (Get-Text 'prepareRecovery')
    Check-Bootloader
    $slot = $script:CheckedBootSlot
    [void](Invoke-Fastboot @('--disable-verity', '--disable-verification', 'flash', "vbmeta_$slot", 'images/vbmeta.img'))
    [void](Invoke-Fastboot @('--disable-verity', '--disable-verification', 'flash', "vbmeta_system_$slot", 'images/vbmeta_system.img'))
    [void](Invoke-Fastboot @('flash', "recovery_$slot", 'tools/TWRP-FUXI-A17.img'))
    [void](Invoke-Fastboot @('reboot', 'recovery'))
    Wait-Adb
    if (((Invoke-Adb @('shell', 'getprop', 'ro.product.device')) -join '').Trim() -ne 'fuxi') { Fail 'Recovery does not report fuxi.' }
    if (-not ((Invoke-Adb @('shell', 'getprop', 'ro.twrp.version.skkk.code')) -join '').Trim()) { Fail 'The bundled TWRP did not start.' }
    [void](Invoke-Adb @('push', 'scripts/prepare-super.sh', '/tmp/prepare-super.sh'))
    [void](Invoke-Adb @('shell', 'sh /tmp/prepare-super.sh audit'))
    $remote = (Invoke-Adb @('shell', 'sha256sum /tmp/fuxi-gpt-before.bin')) -join "`n"
    if ($remote -notmatch '^([0-9a-fA-F]{64})\s+/tmp/fuxi-gpt-before.bin\s*$') { Fail 'Could not read the GPT backup checksum.' }
    $hash = $Matches[1].ToLowerInvariant()
    $backupDir = Join-Path $Root 'backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir ('fuxi-gpt-' + [guid]::NewGuid().ToString('N') + '.bin')
    [void](Invoke-Adb @('pull', '/tmp/fuxi-gpt-before.bin', $backup))
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-Item -LiteralPath $backup).Length -eq 0) { Fail 'The GPT backup was not saved on the computer.' }
    if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $hash) { Fail 'The computer GPT backup does not match the recovery backup.' }
    Set-Content -LiteralPath ($backup + '.sha256') -Value $hash -Encoding ASCII
    Write-Host (Get-Text 'backupPath' @($backup))
    return $hash
}

function Resize-Super([string]$Mode, [string]$Hash) {
    Write-Step (Get-Text 'resize')
    $confirmation = if ($Mode -eq 'apply') { 'ERASE_AND_RESIZE' } else { 'RESTORE_STOCK_SUPER' }
    [void](Invoke-Adb @('shell', "FUXI_CONFIRM=$confirmation FUXI_BACKUP_SHA256=$Hash sh /tmp/prepare-super.sh $Mode"))
    [void](Invoke-Adb @('reboot', 'bootloader'))
    Wait-Fastboot
    Check-Bootloader
    $expected = if ($Mode -eq 'apply') { $ExpandedSuper } else { $StockSuper }
    if ((Get-SuperSize) -ne $expected) { Fail "The requested physical super size $expected was not detected after reboot." }
}
