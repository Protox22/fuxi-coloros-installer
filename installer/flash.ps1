[CmdletBinding()]
param([switch]$Update, [switch]$VerifyOnly, [switch]$InstallerOnly, [switch]$Compact, [ValidateSet('ru', 'en', 'pl')][string]$Language = 'ru')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/common.ps1"

function Expand-SuperImage {
    $required = $SuperSparseBytes + [int64]1073741824
    $candidates = @($env:TEMP, $env:LOCALAPPDATA, $Root) | Where-Object { $_ } | Select-Object -Unique
    foreach ($candidate in $candidates) {
        try {
            $driveName = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($candidate)).TrimEnd('\').TrimEnd(':')
            if ((Get-PSDrive -Name $driveName -PSProvider FileSystem).Free -lt $required) { continue }
            $directory = Join-Path $candidate ('ColorOSFuxi-'  + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $directory | Out-Null
            $script:SuperImage = Join-Path $directory 'super.img'
            break
        } catch { continue }
    }
    if (-not $script:SuperImage) { Fail 'Free space for the decompressed sparse image plus 1 GiB is required in TEMP, LOCALAPPDATA or the release directory.' }
    Write-Step (Get-Text 'unpacking')
    Write-Detail "Unpacking super.img.zst to $script:SuperImage"
    [void](Invoke-Tool $Zstd @('-q', '-d', '--no-sparse', '-o', $script:SuperImage, (Join-Path $Images 'super.img.zst')))
    if ((Get-Item -LiteralPath $script:SuperImage).Length -ne $SuperSparseBytes -or
        (Get-FileHash -LiteralPath $script:SuperImage -Algorithm SHA256).Hash -ne $SuperSha256) {
        Fail 'The decompressed super image has the wrong size or SHA-256.'
    }
    Write-Detail "Decompressed super verified: sparse size $SuperSparseBytes bytes; expanded size 11 GiB."
}

try {
    if ($InstallerOnly -and -not $VerifyOnly) { Fail '-InstallerOnly is allowed only with -VerifyOnly.' }
    Start-Session 'flash'
    Write-Step (Get-Text 'checkingFiles')
    Verify-Payload -InstallerOnly:$InstallerOnly
    if ($VerifyOnly) {
        if ($Compact) { Write-Host ('  ' + (Get-Text 'verified')) -ForegroundColor Green }
        else { Write-Host 'Payload verification completed. No device commands were run.' }
        exit 0
    }
    if ($Update) {
        Write-Detail "$FirmwareName update for an already installed compatible ColorOS port. Userdata and metadata are retained."
    } else { Write-Detail "$FirmwareName FULL installer for Xiaomi 13 (fuxi). Clean install: all userdata is erased." }
    $slotLabel = if ($Update) { 'A' } else { 'A/B' }
    Write-Detail "Required base firmware: Xiaomi Global $RequiredFirmware, active slot $slotLabel."
    Write-Detail "Extra images explicitly selected: $($ExtraImages -join ', '). Unlisted boot images are retained."
    Write-Detail 'Fastboot cannot prove the firmware version of retained boot images.'
    if ($Compact) {
        Write-Host ('  ' + (Get-Text 'requiredBase' @($RequiredFirmware, $slotLabel)))
        if ($ExtraImages.Count) { Write-Host ('  ' + (Get-Text 'extraImages' @($ExtraImages -join ', '))) }
    }
    Write-Step (Get-Text 'checkingDevice')
    $script:AllowedBootSlots = if ($Update) { @('a') } else { @('a', 'b') }
    Connect-Device
    $script:ExpectedBootSlot = $script:CheckedBootSlot
    Write-Detail "Starting slot: $script:ExpectedBootSlot. Flash target: A."
    $superSize = Get-SuperSize
    if ($superSize -notin @($StockSuper, $ExpandedSuper)) { Fail "Unsupported physical super size: $superSize" }
    if ($script:ExpectedBootSlot -eq 'b' -and $superSize -eq $StockSuper) {
        Fail 'Starting from B requires an existing 11 GiB super. The 9 GiB resize path requires A to boot the bundled recovery; no device writes were performed.'
    }
    if ($Update -and $superSize -ne $ExpandedSuper) {
        Fail 'Update without wiping requires an existing 11 GiB super and slot A. No device writes were performed.'
    }
    Check-ExtraImages
    Check-RequiredImages
    $confirmed = if ($Update) {
        Read-Confirmation 'This requires the same already installed compatible ColorOS port. Update while keeping userdata and metadata?' (Get-Text 'confirmUpdate')
    } else { Read-Confirmation 'This permanently erases userdata. Install?' (Get-Text 'confirmInstall') }
    if (-not $confirmed) { Fail 'Cancelled before flashing.' }
    Expand-SuperImage
    if (-not $Update -and $superSize -eq $StockSuper) {
        $backupHash = Start-ResizeRecovery
        if (-not (Read-Confirmation 'Verified GPT backup saved; recovery/AVB already written. Change the partition table?' (Get-Text 'confirmResize'))) { Fail 'Cancelled before changing GPT. Recovery/AVB have already been written; the device remains in TWRP.' }
        Resize-Super 'apply' $backupHash
    }
    Check-Bootloader
    if ((Get-SuperSize) -ne $ExpandedSuper) { Fail '11 GiB super is required before flashing.' }
    Write-Step (Get-Text 'writing')
    [void](Invoke-Fastboot @('flash', 'super', $SuperImage))
    foreach ($name in $ExtraImages) { [void](Invoke-Fastboot @('flash', "${name}_a", "images/$name.img")) }
    [void](Invoke-Fastboot @('flash', 'recovery_a', 'images/recovery.img'))
    [void](Invoke-Fastboot @('flash', 'vbmeta_a', 'images/vbmeta.img'))
    [void](Invoke-Fastboot @('flash', 'vbmeta_system_a', 'images/vbmeta_system.img'))
    if (-not $Update) {
        Write-Step (Get-Text 'wipeReboot')
        [void](Invoke-Fastboot @('erase', 'userdata'))
        [void](Invoke-Fastboot @('erase', 'metadata'))
        Check-Bootloader
        Write-Step (Get-Text 'activate')
        [void](Invoke-Fastboot @('set_active', 'a'))
        $script:ExpectedBootSlot = 'a'
        $script:AllowedBootSlots = @('a')
    } else { Write-Step (Get-Text 'rebootOnly') }
    Check-Bootloader
    [void](Invoke-Fastboot @('reboot'))
    try { Remove-Item -LiteralPath $SuperImage; Remove-Item -LiteralPath (Split-Path -Parent $SuperImage) }
    catch { Write-Warning "Flashing finished; temporary image cleanup failed: $SuperImage" }
    if ($Compact) { $doneKey = if ($Update) { 'updateDone' } else { 'installDone' }; Write-Host ('  ' + (Get-Text $doneKey)) -ForegroundColor Green }
    elseif ($Update) { Write-Host 'Update commands completed without erase or GPT resize; userdata and metadata retained. Reboot requested. Android startup and data accessibility are not verified.' }
    else { Write-Host 'Fastboot commands completed; reboot requested. Android startup has not been verified. Slot A was activated and verified after all writes and erases succeeded.' }
} catch {
    Write-Host ((Get-Text 'error') + ': ' + $_.Exception.Message) -ForegroundColor Red
    if ($SuperImage -and (Test-Path -LiteralPath $SuperImage)) { Write-Detail "Unpacked image retained for diagnosis: $SuperImage" }
    exit 1
} finally { Stop-Session }
