function Resolve-BootVariant([ValidateSet('ksu','no-root')][string]$Mode) {
    $config = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root 'boot-variants.conf')) {
        if ($line -cnotmatch '^([a-z0-9_]+)=([A-Za-z0-9_./-]+)$' -or $config.ContainsKey($Matches[1])) { Fail 'Invalid boot-variants.conf.' }
        $config[$Matches[1]] = $Matches[2]
    }
    $keys = @('format','ksu_image','ksu_sha256','no_root_image','no_root_sha256')
    if ($config.Count -ne 5) { Fail 'Unknown or missing boot variant fields.' }
    foreach ($key in $keys) { if (-not $config.ContainsKey($key)) { Fail 'Missing boot variant field.' } }
    if ($config.format -cne '1' -or $config.ksu_image -cne 'images/boot.img' -or $config.no_root_image -cne 'images/boot-no-root.img') { Fail 'Unsupported boot variant paths.' }
    $key = if ($Mode -eq 'ksu') { 'ksu' } else { 'no_root' }
    $path = Join-Path $Root $config[($key + '_image')]
    $expected = $config[($key + '_sha256')]
    if ($expected -cnotmatch '^[0-9a-f]{64}$' -or -not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { Fail 'Selected boot variant is missing or has the wrong SHA-256.' }
    return $path
}

function Get-ExtraImagePath([string]$Name) {
    if ($Name -eq 'boot' -and $script:SelectedBootImage) { return $script:SelectedBootImage }
    return Join-Path $Images ($Name + '.img')
}

function Select-LocalBootVariant {
    while ($true) {
        Write-Host ('  ' + (Get-Text 'buildTitle')) -ForegroundColor Cyan
        Write-Host ('  [1] ' + (Get-Text 'buildKsu'))
        Write-Host ('  [2] ' + (Get-Text 'buildNoRoot'))
        Write-Host ('  [0] ' + (Get-Text 'buildBack'))
        $choice = Read-Host (Get-Text 'choice')
        if ([string]::IsNullOrWhiteSpace($choice)) { return $null }
        switch -Exact ($choice.Trim()) {
            '1' { return 'ksu' }
            '2' { return 'no-root' }
            '0' { return $null }
            '' { return $null }
            default { Write-Host (Get-Text 'buildInvalid') -ForegroundColor Yellow }
        }
    }
}
