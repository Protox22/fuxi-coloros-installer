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
$lastResult = 0
try {
    :menu while ($true) {
        Write-Host ''
        Write-Host '  FUXI / COLOROS                          v2.6.1' -ForegroundColor Cyan
        Write-Host ('  ' + (Get-Text 'welcome'))
        Write-Host ('  ' + (Get-Text 'intro')) -ForegroundColor Gray
        Write-Host ''
        foreach ($item in @(@('1', 'install'), @('2', 'restore'), @('3', 'verify'), @('4', 'diagnose'), @('5', 'help'), @('6', 'supportReport'))) {
            Write-Host ('  [' + $item[0] + '] ' + (Get-Text $item[1]))
        }
        Write-Host ('  [L] ' + (Get-Text 'language') + ': ' + $Language.ToUpperInvariant() + ' / RU / EN / PL') -ForegroundColor Cyan
        Write-Host ('  [0] ' + (Get-Text 'exit'))
        Write-Host ('  ' + (Get-Text 'eraseWarning')) -ForegroundColor Yellow
        $selection = Read-Host (Get-Text 'choice')
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection.Trim() -eq '0') { exit $lastResult }
        if ($selection.Trim().ToUpperInvariant() -eq 'L') {
            $languages = @('ru', 'en', 'pl')
            $Language = $languages[([array]::IndexOf($languages, $Language) + 1) % 3]
            continue menu
        }
        $parameters = @{ Compact = $true; Language = $Language }
        try {
            switch -Exact ($selection.Trim()) {
                '1' {
                    $buildRoot = $Root
                    if ((Test-BuildReady $Root 'ksu') -or (Test-BuildReady $Root 'no-root')) { $buildRoot = Select-Build $Root }
                    if (-not $buildRoot) { continue menu }
                    while ($true) {
                        Write-Host ('  ' + (Get-Text 'modeTitle')) -ForegroundColor Cyan
                        Write-Host ('  [1] ' + (Get-Text 'modeClean'))
                        Write-Host ('  [2] ' + (Get-Text 'modeUpdate'))
                        Write-Host ('  [0] ' + (Get-Text 'buildBack'))
                        $mode = Read-Host (Get-Text 'choice')
                        if ([string]::IsNullOrWhiteSpace($mode) -or $mode.Trim() -eq '0') { continue menu }
                        if ($mode.Trim() -in @('1', '2')) { break }
                        Write-Host (Get-Text 'modeInvalid') -ForegroundColor Yellow
                    }
                    if ($mode.Trim() -eq '2') { $parameters.Update = $true } else { $parameters.Clean = $true }
                    $entry = Join-Path $buildRoot 'flash.ps1'
                }
                '2' { $entry = Join-Path $Root 'restore-super.ps1' }
                '3' {
                    $entry = Join-Path $Root 'flash.ps1'
                    $parameters.VerifyOnly = $true
                    if (-not (Test-Path -LiteralPath (Join-Path $Root 'images/super.img.zst'))) { $parameters.InstallerOnly = $true }
                }
                '4' { $entry = Join-Path $Root 'check-base.ps1' }
                '6' { $entry = Join-Path $Root 'support-report.ps1' }
                '5' {
                    Get-Content -LiteralPath (Join-Path $Root 'QUICK_START.txt') -Encoding UTF8 | ForEach-Object { Write-Host $_ }
                    if (-not [Console]::IsInputRedirected) { [void](Read-Host (Get-Text 'returnMenu')) }
                    continue menu
                }
                default { Write-Host (Get-Text 'invalid') -ForegroundColor Yellow; continue menu }
            }
            # Call operator creates a script scope; exit returns here. Keeping one
            # process also preserves buffered stdin for scripted/redirected input.
            $global:LASTEXITCODE = 0
            & $entry @parameters
            $lastResult = $LASTEXITCODE
            Set-Location -LiteralPath $Root
            if ($lastResult -eq 1) { Write-Host (Get-Text 'stopped') -ForegroundColor Red }
        } catch {
            $lastResult = 1
            Write-Host ((Get-Text 'error') + ': ' + $_.Exception.Message) -ForegroundColor Red
        }
        if (-not [Console]::IsInputRedirected) { [void](Read-Host (Get-Text 'returnMenu')) }
    }
} finally { [Console]::OutputEncoding = $previousOutputEncoding }
