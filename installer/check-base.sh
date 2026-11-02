#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --language ] || fail 'Usage: bash check-base.sh [--language ru|en|pl]'
    LANGUAGE="$2"
    case "$LANGUAGE" in ru|en|pl) ;; *) fail 'Use ru, en or pl.' ;; esac
fi
read_property() { invoke_adb shell getprop "$1" | tr -d '\r\n'; }
main() {
    INSTALLER_ONLY=1 DIAGNOSTICS_ONLY=1
    start_session check-base
    step checkingFiles
    verify_payload
    show_local_readiness
    find_tools
    ZSTD="${ZSTD:-$(command -v zstd || true)}"
    if [ -n "$ZSTD" ] && [ -x "$ZSTD" ]; then readiness toolsAvailable OK; else readiness toolsAvailable BLOCKED; fi
    get_text checkRequired "$REQUIRED_FIRMWARE"
    local fb adb_devices count state product twrp boot_mode boot_completed system vendor boot_image value
    # Read only. Never use connect_device: it may reboot Android.
    fb="$(get_fastboot_devices)"
    adb_devices="$(get_adb_devices)"
    count="$(printf '%s\n%s\n' "$fb" "$adb_devices" | awk 'NF {n++} END {print n+0}')"
    [ "$count" -eq 1 ] || fail 'Connect exactly one device. For a base check, start Android and authorize USB debugging.'
    if [ -n "$fb" ]; then
        SERIAL="$fb"
        product="$(get_fastboot_var product)"
        [ "$product" = fuxi ] || fail "Connected device is not Xiaomi 13 fuxi: $product"
        local slot unlocked userspace super_size
        slot="$(get_fastboot_var current-slot)"
        unlocked="$(get_fastboot_var unlocked)"
        userspace="$(get_fastboot_var is-userspace)"
        super_size="$(get_super_size)"
        show_fastboot_readiness "$slot" "$unlocked" "$userspace" "$super_size"
        get_text fastbootUnknown
        get_text startAndroid
        return
    fi
    read -r SERIAL state <<< "$adb_devices"
    [ "$state" = device ] || [ "$state" = recovery ] || fail 'Authorize USB debugging on the phone, then retry.'
    product="$(read_property ro.product.device)"
    [ "$product" = fuxi ] || fail "Connected ADB device is not fuxi: $product"
    readiness cleanTechnical UNKNOWN
    readiness updateTechnical UNKNOWN
    twrp="$(read_property ro.twrp.version.skkk.code)"
    boot_mode="$(read_property ro.bootmode)"
    boot_completed="$(read_property sys.boot_completed)"
    if [ "$state" = recovery ] || [ -n "$twrp" ] || [ "$boot_mode" = recovery ] || [ "$boot_completed" != 1 ]; then
        get_text notBooted
        return
    fi
    system="$(read_property ro.build.version.incremental)"
    vendor="$(read_property ro.vendor.build.version.incremental)"
    boot_image="$(read_property ro.bootimage.build.version.incremental)"
    printf 'system=%s vendor=%s bootimage=%s\n' "$system" "$vendor" "$boot_image"
    if [ "$system" = "$REQUIRED_FIRMWARE" ] && [ "$vendor" = "$REQUIRED_FIRMWARE" ] && [ "$boot_image" = "$REQUIRED_FIRMWARE" ]; then
        get_text baseMatch
        get_text noRepeat
    else
        local mismatch=0
        for value in "$system" "$vendor" "$boot_image"; do
            if [ -n "$value" ] && [ "$value" != "$REQUIRED_FIRMWARE" ]; then mismatch=1; fi
        done
        if [ "$mismatch" = 1 ]; then get_text baseMismatch; get_text basePrepare "$REQUIRED_FIRMWARE"
        else get_text baseMissing; fi
    fi
    get_text advisory
    get_text customWarning
}
main
