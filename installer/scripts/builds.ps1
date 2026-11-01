# Optional complete builds live beside this installer, never over its images.
function Get-BuildRoot([string]$Root, [ValidateSet('ksu', 'no-root')][string]$Build) {
    $name = if ($Build -eq 'ksu') { 'FUXI-KSU' } else { 'FUXI-NO-ROOT' }
    return Join-Path (Split-Path -Parent $Root) $name
}

function Test-BuildReady([string]$Root, [string]$Build) {
    $path = Get-BuildRoot $Root $Build
    return (Test-Path -LiteralPath (Join-Path $path 'flash.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $path 'BUILD_TYPE.txt') -PathType Leaf)
}

function Assert-Build([string]$Root, [string]$Build) {
    $path = Get-BuildRoot $Root $Build
    if (-not (Test-BuildReady $Root $Build)) { throw (Get-Text 'buildMissing') }
    $marker = Join-Path $path 'BUILD_TYPE.txt'
    if ([IO.File]::ReadAllText($marker).Trim() -cne $Build) { throw (Get-Text 'buildMismatch') }
    $manifestPath = Join-Path $path 'SHA256SUMS.txt'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw (Get-Text 'buildMismatch') }
    $manifest = [IO.File]::ReadAllText($manifestPath)
    $entries = [regex]::Matches($manifest, '(?m)^([0-9a-fA-F]{64})  \./BUILD_TYPE\.txt\r?$')
    if ($entries.Count -ne 1 -or (Get-FileHash -LiteralPath $marker -Algorithm SHA256).Hash -ine $entries[0].Groups[1].Value) {
        throw (Get-Text 'buildMismatch')
    }
    # Run only the current reviewed shell; each build then verifies its own
    # firmware profile, checksums, partition capacities and device before writes.
    foreach ($name in @('flash.ps1', 'flash.sh', 'restore-super.ps1', 'restore-super.sh',
        'scripts/common.ps1', 'scripts/common.sh', 'scripts/language.ps1',
        'scripts/menu.ps1', 'scripts/builds.ps1', 'scripts/builds.sh', 'scripts/prepare-super.sh')) {
        $candidate = Join-Path $path $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine
            (Get-FileHash -LiteralPath (Join-Path $Root $name) -Algorithm SHA256).Hash) {
            throw (Get-Text 'buildShellMismatch')
        }
    }
    return $path
}

function Select-Build([string]$Root) {
    :buildChoice while ($true) {
        Write-Host ''
        Write-Host ('  ' + (Get-Text 'buildTitle')) -ForegroundColor Cyan
        foreach ($option in @(@('1', 'ksu', 'buildKsu'), @('2', 'no-root', 'buildNoRoot'))) {
            $suffix = if (Test-BuildReady $Root $option[1]) { '' } else { ' (' + (Get-Text 'buildNotAdded') + ')' }
            Write-Host ('     [' + $option[0] + ']  ' + (Get-Text $option[2]) + $suffix)
        }
        Write-Host ('     [3]  ' + (Get-Text 'buildCurrent'))
        Write-Host ('     [0]  ' + (Get-Text 'buildBack'))
        $choice = Read-Host ('  ' + (Get-Text 'choice'))
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim() -eq '0') { return $null }
        switch -Exact ($choice.Trim()) {
            '3' { return $Root }
            '1' { $build = 'ksu' }
            '2' { $build = 'no-root' }
            default { Write-Host (Get-Text 'buildInvalid') -ForegroundColor Yellow; continue buildChoice }
        }
        try { return Assert-Build $Root $build }
        catch { Write-Host $_.Exception.Message -ForegroundColor Yellow }
    }
}
