[CmdletBinding()]
param([switch]$VerifyOnly, [switch]$InstallerOnly, [switch]$Compact, [ValidateSet('ru', 'en', 'pl')][string]$Language = 'ru')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/common.ps1"

try {
    if ($InstallerOnly -and -not $VerifyOnly) { Fail '-InstallerOnly is allowed only with -VerifyOnly.' }
    Start-Session 'restore'
    Write-Step (Get-Text 'checkingFiles')
    # Restoration does not read or flash super.img.zst. Still verify it if present.
    Verify-Payload -InstallerOnly:($InstallerOnly -or -not $VerifyOnly)
    if ($VerifyOnly) { Write-Host 'Payload verification completed. No device commands were run.'; exit 0 }
    Write-Detail 'Xiaomi 13 fuxi: restore the stock 9 GiB super partition boundary.'
    Write-Detail 'This only restores GPT geometry. It does not install stock firmware.'
    if ($Compact) { Write-Host ('  ' + (Get-Text 'restoreTitle')) -ForegroundColor Yellow }
    Write-Step (Get-Text 'checkingDevice')
    Connect-Device
    $superSize = Get-SuperSize
    if ($superSize -eq $StockSuper) {
        if ($Compact) { Write-Host ('  ' + (Get-Text 'alreadyStock')) -ForegroundColor Green }
        else { Write-Host 'Super is already 9 GiB. No partition writes or erases were performed.' }
        exit 0
    }
    if ($superSize -ne $ExpandedSuper) { Fail "Unsupported physical super size: $superSize" }
    Check-RequiredImages
    Write-Detail 'Userdata will be erased. The current ROM will not be bootable after shrinking super.'
    Write-Detail 'Keep the bootloader unlocked. Prepare the correct official fuxi fastboot ROM before continuing.'
    if ($Compact) {
        Write-Host ('  ' + (Get-Text 'eraseCurrent')) -ForegroundColor Yellow
        Write-Host ('  ' + (Get-Text 'prepareStock')) -ForegroundColor Yellow
    }
    if (-not (Read-Confirmation 'Restore stock super size and erase data?' (Get-Text 'confirmRestore'))) { Fail 'Cancelled before flashing.' }
    $backupHash = Start-ResizeRecovery
    if (-not (Read-Confirmation 'Verified GPT backup saved; recovery/AVB already written. Restore the stock GPT boundary?' (Get-Text 'confirmShrink'))) { Fail 'Cancelled before changing GPT. Recovery/AVB have already been written; the device remains in TWRP.' }
    Resize-Super 'restore' $backupHash
    [void](Invoke-Fastboot @('flash', 'recovery_a', 'images/recovery.img'))
    Write-Step (Get-Text 'wipe')
    [void](Invoke-Fastboot @('erase', 'userdata'))
    [void](Invoke-Fastboot @('erase', 'metadata'))
    if ($Compact) {
        Write-Host ('  ' + (Get-Text 'restoreDone')) -ForegroundColor Green
        Write-Host ('  ' + (Get-Text 'installOfficial')) -ForegroundColor Yellow
    } else { Write-Host '9 GiB super boundary verified. Device remains in fastboot. Flash the correct official fuxi ROM before booting Android.' }
} catch {
    Write-Host ((Get-Text 'error') + ': ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally { Stop-Session }
