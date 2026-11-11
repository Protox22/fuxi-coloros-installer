#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ] || [ "${1:-}" = --menu ]; then
    exec bash "$ROOT_DIR/scripts/menu.sh" "${@:2}"
fi
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    printf 'Usage: bash flash.sh [--menu | --clean | --update | --verify-only [--installer-only]] [--language ru|en|pl] [--root-mode ksu|no-root]\n'
    printf 'Optional build: --build ksu|no-root (first argument). No arguments opens the wizard.\n'
    exit 0
fi
if [ "${1:-}" = --build ]; then
    source "$ROOT_DIR/scripts/builds.sh"
    run_selected_build "$ROOT_DIR" "${2:-}" "${@:3}"
    exit $?
fi
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"

expand_super_image() {
    record_event phase.unpack started
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
    [ -n "$SUPER_IMAGE" ] || fail "Free space of $required_bytes bytes is required in writable TMPDIR, ~/.cache or release directory."
    step unpacking
    printf 'Unpacking super.img.zst to %s\n' "$SUPER_IMAGE"
    timeout --foreground --kill-after=5 1800 "$ZSTD" -q -d --no-sparse -o "$SUPER_IMAGE" "$IMAGES/super.img.zst" || fail 'zstd decompression failed or timed out.'
    local size
    size="$(wc -c < "$SUPER_IMAGE")" || fail 'Cannot read the unpacked image.'
    [ "$size" -eq "$SUPER_SPARSE_BYTES" ] && [ "$(hash_file "$SUPER_IMAGE")" = "$SUPER_SHA256" ] ||
        fail 'The decompressed super image has the wrong size or SHA-256.'
    printf 'Decompressed super verified: sparse size %s bytes; expanded size 11 GiB.\n' "$SUPER_SPARSE_BYTES"
}

main() {
    INSTALLER_ONLY=0 UPDATE=0 VERIFY_ONLY=0 ROOT_MODE=ksu
    local clean=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --root-mode) shift; ROOT_MODE="${1:-}"; case "$ROOT_MODE" in ksu|no-root) ;; *) fail "Use --root-mode ksu|no-root." ;; esac ;;
            --update) UPDATE=1 ;;
            --clean) clean=1 ;;
            --compact) COMPACT=1 ;;
            --language) shift; LANGUAGE="${1:-}"; case "$LANGUAGE" in ru|en|pl) ;; *) fail 'Use --language ru|en|pl.' ;; esac ;;
            --verify-only) VERIFY_ONLY=1 ;;
            --installer-only) INSTALLER_ONLY=1 ;;
            *) fail 'Usage: bash flash.sh [--build ksu|no-root] [--clean | --update | --verify-only [--installer-only]]' ;;
        esac
        shift
    done
    [ "$INSTALLER_ONLY" = 0 ] || [ "$VERIFY_ONLY" = 1 ] || fail '--installer-only requires --verify-only.'
    [ "$((clean + UPDATE + VERIFY_ONLY))" -eq 1 ] || fail 'Select exactly one mode: --clean, --update or --verify-only.'
    start_session flash
    step checkingFiles
    verify_payload
    if [ "$VERIFY_ONLY" = 1 ]; then
        if [ ! -f "$IMAGES/super.img.zst" ]; then get_text partialVerified; else get_text verified; fi
        return
    fi
    SELECTED_BOOT_IMAGE="$(resolve_boot_variant "$ROOT_MODE")" || return 1
    NEED_ZSTD=1
    find_tools
    if [ "$UPDATE" = 1 ]; then
        printf '%s update for the same already installed compatible ColorOS port. Userdata and metadata are retained.\n' "$FIRMWARE_NAME"
    else
        printf '%s FULL installer for Xiaomi 13 fuxi. Clean install: all userdata is erased.\n' "$FIRMWARE_NAME"
    fi
    get_text requiredBase "$REQUIRED_FIRMWARE" "$([ "$UPDATE" = 1 ] && printf A || printf A/B)"
    printf 'Extra images explicitly selected: %s. Unlisted boot images are retained.\n' "${EXTRA_IMAGES[*]}"
    printf 'Fastboot cannot prove the firmware version of retained boot images.\n'
    get_text connectHelp
    step checkingDevice
    if [ "$UPDATE" = 0 ]; then ALLOWED_BOOT_SLOTS='a b'; fi
    connect_device
    EXPECTED_BOOT_SLOT="$CHECKED_BOOT_SLOT"
    local super_size confirmation
    super_size="$(get_super_size)"
    [ "$super_size" = "$STOCK_SUPER" ] || [ "$super_size" = "$EXPANDED_SUPER" ] || fail "Unsupported physical super size: $super_size"
    check_extra_images
    check_required_images
    if [ "$UPDATE" = 0 ] && [ "$super_size" = "$STOCK_SUPER" ]; then
        check_required_images "$EXPECTED_BOOT_SLOT"
    fi
    step summary
    printf "Boot variant: %s\n" "$ROOT_MODE"
    get_text firmwareLabel "$FIRMWARE_NAME"
    get_text phoneSummary "$EXPECTED_BOOT_SLOT" "$([ "$super_size" = "$STOCK_SUPER" ] && printf 9 || printf 11)"
    if [ "$UPDATE" = 1 ]; then
        [ "$super_size" = "$EXPANDED_SUPER" ] || fail 'Update without wiping requires an existing 11 GiB super and slot A. No device writes were performed.'
        get_text updateAdvice
        confirm "$(get_text confirmUpdate)" || { get_text cancelled; return 2; }
    else
        [ "$super_size" != "$STOCK_SUPER" ] || get_text resizePlan "${EXPECTED_BOOT_SLOT^^}"
        confirm "$(get_text baseConsent "$REQUIRED_FIRMWARE")" || { get_text cancelled; return 2; }
    fi
    expand_super_image
    if [ "$UPDATE" = 0 ] && [ "$super_size" = "$STOCK_SUPER" ]; then
        start_resize_recovery
        confirm "$(get_text confirmResize)" || fail 'Cancelled before changing GPT. Recovery/AVB have already been written; the device remains in TWRP.'
        resize_super apply
    fi
    check_bootloader
    [ "$(get_super_size)" = "$EXPANDED_SUPER" ] || fail '11 GiB super is required before flashing.'
    invoke_fastboot flash super "$SUPER_IMAGE"
    local name
    for name in "${EXTRA_IMAGES[@]}"; do invoke_fastboot flash "${name}_a" "$(extra_image_path "$name")"; done
    invoke_fastboot flash recovery_a "$IMAGES/recovery.img"
    invoke_fastboot flash vbmeta_a "$IMAGES/vbmeta.img"
    invoke_fastboot flash vbmeta_system_a "$IMAGES/vbmeta_system.img"
    if [ "$UPDATE" = 0 ]; then
        invoke_fastboot erase userdata
        invoke_fastboot erase metadata
        check_bootloader
        step activate
        invoke_fastboot set_active a
        EXPECTED_BOOT_SLOT=a ALLOWED_BOOT_SLOTS=a
    fi
    check_bootloader
    invoke_fastboot reboot
    if [ "$UPDATE" = 1 ]; then
        get_text updateDone
    else
        get_text installDone
    fi
}
main "$@"
