#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"

main() {
    INSTALLER_ONLY=0
    if [ "$#" -eq 2 ] && [ "$1" = --verify-only ] && [ "$2" = --installer-only ]; then INSTALLER_ONLY=1
    else [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && [ "$1" = --verify-only ]; } || fail 'Usage: bash restore-super.sh [--verify-only [--installer-only]]'; fi
    start_session restore
    # Restoration does not read or flash super.img.zst. Still verify it if present.
    if [ "$#" -eq 0 ]; then INSTALLER_ONLY=1; fi
    verify_payload
    if [ "$#" -gt 0 ]; then printf 'Payload verification completed. No device commands were run.\n'; return; fi
    find_tools
    printf 'Xiaomi 13 fuxi: restore the stock 9 GiB super partition boundary.\n'
    printf 'This only restores GPT geometry. It does not install stock firmware.\n'
    connect_device
    local super_size confirmation
    super_size="$(get_super_size)"
    if [ "$super_size" = "$STOCK_SUPER" ]; then
        printf 'Super is already 9 GiB. No partition writes or erases were performed.\n'
        return
    fi
    [ "$super_size" = "$EXPANDED_SUPER" ] || fail "Unsupported physical super size: $super_size"
    check_required_images
    printf 'Userdata will be erased. The current ROM will not be bootable after shrinking super.\n'
    printf 'Keep the bootloader unlocked. Prepare the correct official fuxi fastboot ROM before continuing.\n'
    confirm 'Restore stock super size and erase data?' || fail 'Cancelled before flashing.'
    start_resize_recovery
    confirm 'Verified GPT backup saved; recovery/AVB already written. Restore the stock GPT boundary?' || fail 'Cancelled before changing GPT. Recovery/AVB have already been written; the device remains in TWRP.'
    resize_super restore
    invoke_fastboot flash recovery_a "$IMAGES/recovery.img"
    invoke_fastboot erase userdata
    invoke_fastboot erase metadata
    printf '9 GiB super boundary verified. Device remains in fastboot. Flash the correct official fuxi ROM before booting Android.\n'
}
main "$@"
