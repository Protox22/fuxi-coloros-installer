# Native process execution with concurrent stdout/stderr draining and a deadline.
# No shell is used: spaces, ampersands and non-ASCII paths remain literal arguments.
function ConvertTo-NativeArgument([string]$Value) {
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-Tool([string]$Executable, [string[]]$Arguments, [switch]$Quiet, [int]$TimeoutSeconds = 0) {
    if ($TimeoutSeconds -eq 0) {
        $TimeoutSeconds = if ($Arguments -contains 'getvar' -or $Arguments -contains 'devices' -or $Arguments -contains 'start-server') { 15 }
            elseif ($Arguments -contains 'get-state') { 5 }
            elseif ($Executable -eq $Zstd) { 1800 }
            elseif ($Executable -eq $Adb) { 300 } else { 1200 }
    }
    Write-Detail ('> ' + $Executable + ' ' + ($Arguments -join ' ')) -Quiet
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $process.StartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextNotice = 15
    try {
        if (-not $process.Start()) { Fail "Cannot start required tool: $Executable" }
        $stdout = $process.StandardOutput.ReadLineAsync()
        $stderr = $process.StandardError.ReadLineAsync()
        while ($null -ne $stdout -or $null -ne $stderr -or -not $process.HasExited) {
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { Fail "Timed out after ${TimeoutSeconds}s: $([IO.Path]::GetFileName($Executable)) $($Arguments -join ' ')" }
            if ($null -ne $stdout -and $stdout.IsCompleted) {
                $line = $stdout.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdout = $null }
                else { $lines.Add($line); Write-Detail $line -Quiet:$Quiet; $stdout = $process.StandardOutput.ReadLineAsync() }
            }
            if ($null -ne $stderr -and $stderr.IsCompleted) {
                $line = $stderr.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderr = $null }
                else { $lines.Add($line); Write-Detail $line -Quiet:$Quiet; $stderr = $process.StandardError.ReadLineAsync() }
            }
            if (-not $Quiet -and $Compact -and $timer.Elapsed.TotalSeconds -ge $nextNotice) {
                Write-Host ('  ' + (Get-Text 'progressWait'))
                $nextNotice += 15
            }
            Start-Sleep -Milliseconds 10
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { Fail "$([IO.Path]::GetFileName($Executable)) failed (exit $($process.ExitCode)): $($Arguments -join ' ')" }
        return $lines.ToArray()
    } finally {
        try { if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) } } catch {}
        $process.Dispose()
    }
}
