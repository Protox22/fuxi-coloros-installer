[CmdletBinding()]
param([switch]$Compact, [ValidateSet('ru','en','pl')][string]$Language='en')
. "$PSScriptRoot/scripts/common.ps1"
$reportCreated = $false
try {
    # Export only our fixed vocabulary, never transcripts, GPT backups or native output.
    $pattern = '^(session\.(flash|restore|check-base)|phase\.(verify|device|unpack)|flash\.(super|boot_a|init_boot_a|vendor_boot_a|dtbo_a|(recovery|vbmeta|vbmeta_system)_[ab])|erase\.(userdata|metadata)|activate\.a|gpt\.resize|result|error|ready\.(toolsAvailable|bundlePresent|firmwareHashes|compatibility|diskSpace|cleanTechnical|updateTechnical))\t(started|done|finished|unfinished|failed|cancelled|OK|BLOCKED|UNKNOWN|hintFiles|hintLock|hintSpace|hintSlot|hintTools|hintUsb|hintStopped)$'
    $source = $null
    $logs = Join-Path $Root 'logs'
    if (Test-Path -LiteralPath $logs) {
        if ((Get-Item -LiteralPath $logs).Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Linked logs directory is not supported.' }
        foreach ($file in (Get-ChildItem -LiteralPath $logs -Filter '*.events.tsv' -File | Sort-Object LastWriteTimeUtc -Descending)) {
            if ($file.Length -gt 8388608 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if ((Get-Content -LiteralPath $file.FullName -TotalCount 1) -match '^session\.(flash|restore|check-base)\tstarted$') { $source = $file; break }
        }
    }
    if (-not $source) { Fail 'No structured session found. Run option 4, or an operation with installer 2.6, then retry.' }
    Start-Session 'export'
    $safe = @((Get-Content -LiteralPath $source.FullName) | Where-Object { $_ -cmatch $pattern })
    $reports = Join-Path $Root 'reports'
    New-Item -ItemType Directory -Force -Path $reports | Out-Null
    if ((Get-Item -LiteralPath $reports).Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'Linked report directory is not supported.' }
    $destination = Join-Path $reports ('FUXI-support-' + [guid]::NewGuid().ToString('N') + '.zip')
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($destination, 'CreateNew', 'Write', 'None')
    $reportCreated = $true
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $content = @{
                'events.tsv' = ($safe -join "`n") + "`n"
                'README.txt' = "FUXI installer 2.6.1 R2187 - latest structured session`nOnly fixed operation/status codes are included. No serial, local paths, raw logs, firmware or GPT backups.`nUNKNOWN is not readiness approval. done means a command returned success, not verified Android startup.`nAn interrupted started write may be partially applied. Do not resume midway.`n"
            }
            foreach ($name in $content.Keys) {
                $entry = $archive.CreateEntry($name)
                $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding $false))
                try { $writer.Write($content[$name]) } finally { $writer.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
    Write-Host (Get-Text 'reportCreated' @($destination))
    $script:SessionOutcome = 'finished'
} catch {
    $script:SessionOutcome = 'failed'
    if ($reportCreated) { Remove-Item -LiteralPath $destination -ErrorAction SilentlyContinue }
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally { Stop-Session }
