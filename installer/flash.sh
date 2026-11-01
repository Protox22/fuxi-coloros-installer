#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = --build ]; then
    source "$ROOT_DIR/scripts/builds.sh"
    run_selected_build "$ROOT_DIR" "${2:-}" "${@:3}"
    exit $?
fi
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"

expand_super_image() {
    local candidate directory free_kb
    local required_bytes=$((SUPER_SPARSE_BYTES + 1073741824))
    for candidate in "${TMPDIR:-/tmp}" "${HOME:-/tmp}/.cache" "$ROOT"; do
        [ -d "$candidate" ] && [ -w "$candidate" ] || continue
        free_kb="$(df -Pk "$candidate" | awk 'END {print $4}')" || continue
        [[ "$free_kb" =~ ^[0-9]+$ ]] || continue
        [ "$((free_kb * 1024))" -ge "$required_bytes" ] || continue
        directory="$(mktemp -d "$candidate/ColorOS17FuxiV16.XXXXXXXX")" || continue
        SUPER_IMAGE="$directory/super.img"
        break
    done
    [ -n "$SUPER_IMAGE" ] || fail 'At least 10.4 GiB free in writable TMPDIR, ~/.cache or release directory is required.'
    printf 'Unpacking super.img.zst to %s\n' "$SUPER_IMAGE"
    "$ZSTD" -q -d --no-sparse -o "$SUPER_IMAGE" "$IMAGES/super.img.zst" || fail 'zstd decompression failed.'
    local size
    size="$(wc -c < "$SUPER_IMAGE")" || fail 'Cannot read the unpacked image.'
    [ "$size" -eq "$SUPER_SPARSE_BYTES" ] && [ "$(hash_file "$SUPER_IMAGE")" = "$SUPER_SHA256" ] ||
        fail 'The decompressed super image has the wrong size or SHA-256.'
    printf 'Decompressed super verified: sparse size %s bytes; expanded size 11 GiB.\n' "$SUPER_SPARSE_BYTES"
}

main() {
    INSTALLER_ONLY=0 UPDATE=0 VERIFY_ONLY=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --update) UPDATE=1 ;;
            --verify-only) VERIFY_ONLY=1 ;;
            --installer-only) INSTALLER_ONLY=1 ;;
            *) fail 'Usage: bash flash.sh [--build ksu|no-root] [--update] [--verify-only [--installer-only]]' ;;
        esac
        shift
    done
    [ "$INSTALLER_ONLY" = 0 ] || [ "$VERIFY_ONLY" = 1 ] || fail '--installer-only requires --verify-only.'
    start_session flash
    verify_payload
    if [ "$VERIFY_ONLY" = 1 ]; then printf 'Payload verification completed. No device commands were run.\n'; return; fi
    NEED_ZSTD=1
    find_tools
    if [ "$UPDATE" = 1 ]; then
        printf '%s update for the same already installed compatible ColorOS port. Userdata and metadata are retained.\n' "$FIRMWARE_NAME"
    else
        printf '%s FULL installer for Xiaomi 13 fuxi. Clean install: all userdata is erased.\n' "$FIRMWARE_NAME"
    fi
    printf 'Required starting firmware: Xiaomi Global %s, active slot A.\n' "$REQUIRED_FIRMWARE"
    printf 'Extra images explicitly selected: %s. Unlisted boot images are retained.\n' "${EXTRA_IMAGES[*]}"
    printf 'Fastboot cannot prove the firmware version of retained boot images.\n'
    connect_device
    local super_size confirmation
    super_size="$(get_super_size)"
    [ "$super_size" = "$STOCK_SUPER" ] || [ "$super_size" = "$EXPANDED_SUPER" ] || fail "Unsupported physical super size: $super_size"
    check_extra_images
    check_required_images
    if [ "$UPDATE" = 1 ]; then
        [ "$super_size" = "$EXPANDED_SUPER" ] || fail 'Update without wiping requires an existing 11 GiB super and slot A. No device writes were performed.'
        confirm 'This requires the same already installed compatible ColorOS port. Update while keeping userdata and metadata?' || fail 'Cancelled before flashing.'
    else
        confirm 'This permanently erases userdata. Install?' || fail 'Cancelled before flashing.'
    fi
    expand_super_image
    if [ "$UPDATE" = 0 ] && [ "$super_size" = "$STOCK_SUPER" ]; then
        start_resize_recovery
        confirm 'Verified GPT backup saved; recovery/AVB already written. Change GPT?' || fail 'Cancelled before changing GPT. Recovery/AVB have already been written; the device remains in TWRP.'
        resize_super apply
    fi
    check_bootloader
    [ "$(get_super_size)" = "$EXPANDED_SUPER" ] || fail '11 GiB super is required before flashing.'
    invoke_fastboot flash super "$SUPER_IMAGE"
    local name
    for name in "${EXTRA_IMAGES[@]}"; do invoke_fastboot flash "${name}_a" "$IMAGES/$name.img"; done
    invoke_fastboot flash recovery_a "$IMAGES/recovery.img"
    invoke_fastboot flash vbmeta_a "$IMAGES/vbmeta.img"
    invoke_fastboot flash vbmeta_system_a "$IMAGES/vbmeta_system.img"
    if [ "$UPDATE" = 0 ]; then
        invoke_fastboot erase userdata
        invoke_fastboot erase metadata
    fi
    check_bootloader
    invoke_fastboot reboot
    if ! rm -f "$SUPER_IMAGE" || ! rmdir "$(dirname "$SUPER_IMAGE")"; then
        printf 'Flashing finished; temporary image cleanup failed: %s\n' "$SUPER_IMAGE" >&2
    fi
    if [ "$UPDATE" = 1 ]; then
        printf 'Update commands completed without erase or GPT resize; userdata and metadata retained. Android startup and data accessibility are not verified.\n'
    else
        printf 'Fastboot commands completed; reboot requested. Android startup has not been verified. Slot A was retained.\n'
    fi
}
main "$@"
