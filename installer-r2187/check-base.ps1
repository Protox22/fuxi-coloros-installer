[CmdletBinding()]
param([switch]$Compact, [ValidateSet('ru', 'en', 'pl')][string]$Language = 'en')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/scripts/common.ps1"

function Read-DeviceProperty([string]$Name) {
    return ((Invoke-Adb @('shell', 'getprop', $Name) -Quiet) -join '').Trim()
}

try {
    Start-Session 'check-base'
    Write-Step (Get-Text 'checkingFiles')
    Verify-Payload -InstallerOnly -DiagnosticsOnly
    Show-LocalReadiness
    Write-Readiness 'toolsAvailable' 'OK'
    Write-Host ('  ' + (Get-Text 'checkRequired' @($RequiredFirmware)))
    # Read only: do not call Connect-Device, which may reboot Android.
    $fastbootDevices = @(Get-FastbootDevices)
    $adbDevices = @(Get-AdbDevices)
    if ($fastbootDevices.Count + $adbDevices.Count -ne 1) { Fail 'Connect exactly one device. For a base check, start Android and authorize USB debugging.' }
    if ($fastbootDevices.Count -eq 1) {
        $script:Serial = $fastbootDevices[0]
        if ((Get-FastbootVar 'product') -ne 'fuxi') { Fail 'Connected device is not Xiaomi 13 fuxi.' }
        Show-FastbootReadiness (Get-FastbootVar 'current-slot') (Get-FastbootVar 'unlocked') (Get-FastbootVar 'is-userspace') (Get-SuperSize)
        Write-Detail 'Base diagnosis: unconfirmed-fastboot'
        Write-Host ('  ' + (Get-Text 'fastbootUnknown')) -ForegroundColor Yellow
        Write-Host ('  ' + (Get-Text 'startAndroid'))
        $script:SessionOutcome = 'finished'
        exit 0
    }
    if ($adbDevices[0] -notmatch '^(\S+)\s+(device|recovery)\s*$') { Fail 'Authorize USB debugging on the phone, then retry.' }
    $script:Serial = $Matches[1]
    $adbState = $Matches[2]
    if ((Read-DeviceProperty 'ro.product.device') -ne 'fuxi') { Fail 'Connected ADB device is not fuxi.' }
    Write-Readiness 'cleanTechnical' 'UNKNOWN'
    Write-Readiness 'updateTechnical' 'UNKNOWN'
    $twrp = Read-DeviceProperty 'ro.twrp.version.skkk.code'
    $bootMode = Read-DeviceProperty 'ro.bootmode'
    $bootCompleted = Read-DeviceProperty 'sys.boot_completed'
    if ($adbState -eq 'recovery' -or $twrp -or $bootMode -eq 'recovery' -or $bootCompleted -ne '1') {
        Write-Detail 'Base diagnosis: unconfirmed-recovery-or-boot'
        Write-Host ('  ' + (Get-Text 'notBooted')) -ForegroundColor Yellow
        $script:SessionOutcome = 'finished'
        exit 0
    }
    $system = Read-DeviceProperty 'ro.build.version.incremental'
    $vendor = Read-DeviceProperty 'ro.vendor.build.version.incremental'
    $bootImage = Read-DeviceProperty 'ro.bootimage.build.version.incremental'
    Write-Detail "Reported system=$system vendor=$vendor bootimage=$bootImage"
    foreach ($property in @('ro.build.fingerprint', 'ro.vendor.build.fingerprint', 'ro.bootimage.build.fingerprint')) {
        $value = Read-DeviceProperty $property
        Write-Detail "$property=$value"
    }
    if ($system -ceq $RequiredFirmware -and $vendor -ceq $RequiredFirmware -and $bootImage -ceq $RequiredFirmware) {
        Write-Detail 'Base diagnosis: metadata-match'
        Write-Host ('  ' + (Get-Text 'baseMatch')) -ForegroundColor Green
        Write-Host ('  ' + (Get-Text 'noRepeat'))
    } elseif (@($system, $vendor, $bootImage | Where-Object { $_ -and $_ -cne $RequiredFirmware }).Count) {
        Write-Detail 'Base diagnosis: metadata-mismatch'
        Write-Host ('  ' + (Get-Text 'baseMismatch')) -ForegroundColor Yellow
        Write-Host ('  ' + (Get-Text 'basePrepare' @($RequiredFirmware)))
    } else {
        Write-Detail 'Base diagnosis: unconfirmed-missing-properties'
        Write-Host ('  ' + (Get-Text 'baseMissing')) -ForegroundColor Yellow
    }
    Write-Host ('  ' + (Get-Text 'advisory')) -ForegroundColor DarkGray
    Write-Host ('  ' + (Get-Text 'customWarning')) -ForegroundColor Yellow
    $script:SessionOutcome = 'finished'
} catch {
    Write-Host ((Get-Text 'error') + ': ' + $_.Exception.Message) -ForegroundColor Red
    Show-ErrorHint $_.Exception.Message
    exit 1
} finally { Stop-Session }
