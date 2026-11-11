# Structured journal deliberately contains no native output, serials or paths.
$EventFile = ''
$SessionOutcome = 'unfinished' # Ctrl+C may reach finally without entering catch.
$LastMutation = ''
$CurrentPhase = 'startup'
$CompletedMutations = New-Object 'System.Collections.Generic.List[string]'
function Write-Event([string]$Action, [string]$State) {
    if ($Action.StartsWith('phase.')) { $script:CurrentPhase = $Action }
    if ($script:EventFile) { [IO.File]::AppendAllText($script:EventFile, "$Action`t$State`n", [Text.Encoding]::ASCII) }
}
function Get-Mutation([string]$Tool, [string[]]$Arguments) {
    if ($Tool -eq 'fastboot') {
        $index = [array]::IndexOf($Arguments, 'flash')
        if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
            $partition = $Arguments[$index + 1]
            if ($partition -match '^(super|boot_a|init_boot_a|vendor_boot_a|dtbo_a|(recovery|vbmeta|vbmeta_system)_[ab])$') { return "flash.$partition" }
        }
        if ($Arguments[0] -eq 'erase' -and $Arguments[1] -in @('userdata', 'metadata')) { return 'erase.' + $Arguments[1] }
        if ($Arguments[0] -eq 'set_active') { return 'activate.a' }
    } elseif (($Arguments -join ' ') -match 'FUXI_CONFIRM=') { return 'gpt.resize' }
    return ''
}
function Invoke-DeviceTool([string]$Tool, [string[]]$Arguments) {
    $action = Get-Mutation $Tool $Arguments
    if ($action) {
        Write-Event $action 'started' # Persist before the native command starts.
        $script:LastMutation = $action
    }
    $executable = if ($Tool -eq 'fastboot') { $Fastboot } else { $Adb }
    $output = Invoke-Tool $executable (@('-s', $script:Serial) + $Arguments)
    if ($action) {
        Write-Event $action 'done'
        $script:CompletedMutations.Add($action)
    }
    return $output
}
function Show-FailureState {
    $script:SessionOutcome = 'failed'
    Write-Event 'result' 'failed'
    Write-Host (Get-Text 'failureState') -ForegroundColor Yellow
    Write-Host ('  ' + $script:CurrentPhase)
    if ($script:LastMutation) {
        Write-Host (Get-Text 'partialWrites') -ForegroundColor Yellow
        Write-Host (Get-Text 'lastWrite' @($script:LastMutation))
        Write-Host (Get-Text 'doneWrites' @($script:CompletedMutations -join ', '))
    } else { Write-Host (Get-Text 'noWrites') }
    Write-Host (Get-Text 'reportHelp')
}
function Write-Readiness([string]$Name, [string]$State) {
    Write-Event "ready.$Name" $State
    Write-Host ('  ' + (Get-Text $Name) + ': ' + $State)
}
function Show-LocalReadiness {
    Write-Host (Get-Text 'quickScope') -ForegroundColor Yellow
    $missing = @()
    foreach ($name in (@('super.img.zst', 'recovery.img', 'vbmeta.img', 'vbmeta_system.img') + @($ExtraImages | ForEach-Object { "$_.img" }))) {
        if (-not (Test-Path -LiteralPath (Join-Path $Images $name) -PathType Leaf)) { $missing += $name }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'tools/TWRP-FUXI-A17.img'))) { $missing += 'TWRP' }
    Write-Readiness 'bundlePresent' $(if ($missing.Count) { 'BLOCKED' } else { 'OK' })
    if ($missing.Count) { Write-Host ($missing -join ', ') }
    Write-Readiness 'firmwareHashes' 'UNKNOWN'
    Write-Readiness 'compatibility' 'UNKNOWN'
    $space = $false
    foreach ($candidate in @($env:TEMP, $env:LOCALAPPDATA, $Root)) {
        if (-not $candidate) { continue }
        try {
            $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($candidate)))
            if ($drive.AvailableFreeSpace -ge $SuperSparseBytes + 1073741824) { $space = $true }
        } catch {}
    }
    Write-Readiness 'diskSpace' $(if ($space) { 'OK' } else { 'BLOCKED' })
    Write-Host (Get-Text 'spaceProbe')
}
function Show-FastbootReadiness([string]$Slot, [string]$Unlocked, [string]$Userspace, [string]$Size) {
    $base = $Unlocked -eq 'yes' -and $Userspace -eq 'no'
    $slot = $Slot.TrimStart('_')
    Write-Readiness 'cleanTechnical' $(if ($base -and $slot -in @('a','b') -and $Size -in @($StockSuper, $ExpandedSuper)) { 'OK' } else { 'BLOCKED' })
    Write-Readiness 'updateTechnical' $(if ($base -and $Size -eq $ExpandedSuper -and $slot -eq 'a') { 'OK' } else { 'BLOCKED' })
}
