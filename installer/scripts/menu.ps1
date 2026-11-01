[CmdletBinding()]
param([ValidateSet('ru', 'en', 'pl')][string]$Language = 'ru')
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Import-Module "$PSHOME/Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1" -Force
}
$Root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/language.ps1"
. "$PSScriptRoot/builds.ps1"
$previousOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

try {
function Show-Menu {
    if (-not [Console]::IsOutputRedirected) { Clear-Host }
    Write-Host ''
    Write-Host '  +------------------------------------------------------+' -ForegroundColor DarkCyan -BackgroundColor Black
    Write-Host '  |  F U X I                              C O L O R O S  |' -ForegroundColor Cyan -BackgroundColor Black
    Write-Host '  |  Xiaomi 13                                    v2.4.1 |' -ForegroundColor Gray -BackgroundColor Black
    Write-Host '  |  Port by tomekcz                                     |' -ForegroundColor DarkGray -BackgroundColor Black
    Write-Host '  +------------------------------------------------------+' -ForegroundColor DarkCyan -BackgroundColor Black
    Write-Host ''
    Write-Host ('     [1]  ' + (Get-Text 'install')) -ForegroundColor White
    Write-Host ('     [2]  ' + (Get-Text 'restore')) -ForegroundColor White
    Write-Host ('     [3]  ' + (Get-Text 'verify')) -ForegroundColor Gray
    Write-Host ('     [4]  ' + (Get-Text 'base')) -ForegroundColor Gray
    Write-Host ('     [L]  ' + (Get-Text 'language') + ': RU / EN / PL  [' + $Language.ToUpperInvariant() + ']') -ForegroundColor Cyan
    Write-Host ('     [0]  ' + (Get-Text 'exit')) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  ' + (Get-Text 'eraseWarning')) -ForegroundColor Yellow
    Write-Host ''
}

:menu while ($true) {
    Show-Menu
    $selection = Read-Host ('  ' + (Get-Text 'choice'))
    if ([string]::IsNullOrWhiteSpace($selection)) { exit 0 }
    if ($selection.Trim().ToUpperInvariant() -eq 'L') {
        $languages = @('ru', 'en', 'pl')
        $Language = $languages[([array]::IndexOf($languages, $Language) + 1) % $languages.Count]
        continue menu
    }
    $parameters = @{ Compact = $true; Language = $Language }
    switch -Exact ($selection.Trim()) {
        '0' { exit 0 }
        '1' {
            $buildRoot = Select-Build $Root
            if (-not $buildRoot) { continue menu }
            Write-Host ('  ' + (Get-Text 'modeTitle')) -ForegroundColor Cyan
            Write-Host ('     [1]  ' + (Get-Text 'modeClean'))
            Write-Host ('     [2]  ' + (Get-Text 'modeUpdate'))
            Write-Host ('     [0]  ' + (Get-Text 'buildBack'))
            $mode = Read-Host ('  ' + (Get-Text 'choice'))
            if ([string]::IsNullOrWhiteSpace($mode) -or $mode.Trim() -eq '0') { continue menu }
            if ($mode.Trim() -eq '2') { $parameters.Update = $true }
            elseif ($mode.Trim() -ne '1') { Write-Host (Get-Text 'modeInvalid') -ForegroundColor Yellow; continue menu }
            $entry = Join-Path $buildRoot 'flash.ps1'
        }
        '2' { $entry = Join-Path $Root 'restore-super.ps1' }
        '4' { $entry = Join-Path $Root 'check-base.ps1' }
        '3' {
            $entry = Join-Path $Root 'flash.ps1'
            $parameters.VerifyOnly = $true
            if (-not (Test-Path -LiteralPath (Join-Path $Root 'images/super.img.zst') -PathType Leaf)) {
                Write-Host ('  ' + (Get-Text 'missingSuper')) -ForegroundColor Yellow
                $parameters.InstallerOnly = $true
            }
        }
        default { Write-Host ('  ' + (Get-Text 'invalid')) -ForegroundColor Yellow; continue menu }
    }
    break
}
try {
    $global:LASTEXITCODE = 0
    & $entry @parameters
    $succeeded = $?
    $code = $LASTEXITCODE
    if ($code -ne 0 -or -not $succeeded) {
        Write-Host ('  ' + (Get-Text 'stopped')) -ForegroundColor Red
        if ($code -ne 0) { exit $code }
        exit 1
    }
    exit 0
} catch {
    Write-Host ((Get-Text 'error') + ': ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if (-not [Console]::IsInputRedirected) {
        Write-Host ''
        [void](Read-Host ('  ' + (Get-Text 'close')))
    }
}
} finally { [Console]::OutputEncoding = $previousOutputEncoding }
