# Shared explicit consent for bootloader restarts.
read_safety_consent() {
    local answer
    printf '%s\nType YES to confirm; any other answer cancels: ' "$1"
    read -r answer || return 1
    [ "$answer" = YES ]
}

confirm_bootloader_restart() {
    read_safety_consent 'Allow this operation to restart the selected phone into bootloader fastboot when needed?' || fail 'Bootloader restart cancelled.'
}