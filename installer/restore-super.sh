#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"

main() {
    INSTALLER_ONLY=0
    local verify_only=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --verify-only) verify_only=1 ;;
            --installer-only) INSTALLER_ONLY=1 ;;
            --language) shift; LANGUAGE="${1:-}"; case "$LANGUAGE" in ru|en|pl) ;; *) fail 'Use ru, en or pl.' ;; esac ;;
            *) fail 'Usage: bash restore-super.sh [--verify-only [--installer-only]] [--language ru|en|pl]' ;;
        esac
        shift
    done
    [ "$INSTALLER_ONLY" = 0 ] || [ "$verify_only" = 1 ] || fail '--installer-only requires --verify-only.'
    start_session restore
    # Restoration does not read or flash super.img.zst. Still verify it if present.
    if [ "$verify_only" = 0 ]; then INSTALLER_ONLY=1; fi
    verify_payload
    if [ "$verify_only" = 1 ]; then
        if [ -f "$IMAGES/super.img.zst" ]; then get_text verified; else get_text partialVerified; fi
        return
    fi
    find_tools
    get_text restoreTitle
    get_text connectHelp
    connect_device
    local super_size confirmation
    super_size="$(get_super_size)"
    if [ "$super_size" = "$STOCK_SUPER" ]; then
        get_text alreadyStock
        return
    fi
    [ "$super_size" = "$EXPANDED_SUPER" ] || fail "Unsupported physical super size: $super_size"
    check_required_images
    get_text eraseCurrent
    get_text prepareStock
    confirm "$(get_text confirmRestore)" || { get_text cancelled; return 2; }
    start_resize_recovery
    confirm "$(get_text confirmShrink)" || fail 'Cancelled before changing GPT. Recovery/AVB have already been written; the device remains in TWRP.'
    resize_super restore
    invoke_fastboot flash recovery_a "$IMAGES/recovery.img"
    invoke_fastboot erase userdata
    invoke_fastboot erase metadata
    get_text restoreDone
    get_text installOfficial
}
main "$@"
