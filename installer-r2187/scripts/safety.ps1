# Shared explicit consent for bootloader restarts.
function Read-SafetyConsent([string]$Prompt) {
    Write-Host $Prompt -ForegroundColor Yellow
    try { $answer = Read-Host 'Type YES to confirm; any other answer cancels' } catch { return $false }
    return ($answer -ceq 'YES')
}

function Confirm-BootloaderRestart {
    if (-not (Read-SafetyConsent 'Allow this operation to restart the selected phone into bootloader fastboot when needed?')) { Fail 'Bootloader restart cancelled.' }
}
