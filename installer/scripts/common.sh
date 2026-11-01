# Shared host-side checks for flash.sh and restore-super.sh. Bash, not recovery sh.
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IMAGES="$ROOT/images"
SCRIPTS="$ROOT/scripts"
TOOLS="$ROOT/tools"
STOCK_SUPER=0x240000000
EXPANDED_SUPER=0x2c0000000
SERIAL=''
SUPER_IMAGE=''
LOCK_OWNED=0

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    [ -z "$SUPER_IMAGE" ] || printf 'Unpacked image retained for diagnosis: %s\n' "$SUPER_IMAGE" >&2
    exit 1
}

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print tolower($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print tolower($1)}'
    else
        fail 'sha256sum or shasum is required.'
    fi
}

confirm() {
    local answer
    while true; do
        read -r -p "$1 [y/N]: " answer || return 1
        case "$answer" in
            y|Y) return 0 ;;
            n|N|'') return 1 ;;
            *) printf 'Enter y or n.\n' ;;
        esac
    done
}

verify_payload() {
    local line expected relative actual seen=$'\n'
    [ -f "$ROOT/SHA256SUMS.txt" ] || fail 'SHA256SUMS.txt is missing.'
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^([0-9a-fA-F]{64})\ \ (\./)?([A-Za-z0-9_./-]+)$ ]] || fail "Invalid checksum entry: $line"
        expected="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        relative="${BASH_REMATCH[3]}"
        case "/$relative/" in *'/../'*|*'/./'*|'//'*) fail "Unsafe checksum path: $relative" ;; esac
        [[ "$seen" != *$'\n'"$relative"$'\n'* ]] || fail "Duplicate checksum path: $relative"
        seen+="$relative"$'\n'
        if [ ! -f "$ROOT/$relative" ]; then
            if [ "${INSTALLER_ONLY:-0}" = 1 ] && [ "$relative" = images/super.img.zst ]; then
                printf 'OMITTED  images/super.img.zst (installer-only check)\n'
                continue
            fi
            fail "Required release file is missing: $relative"
        fi
        actual="$(hash_file "$ROOT/$relative")" || fail "Cannot hash: $relative"
        [ "$actual" = "$expected" ] || fail "SHA-256 mismatch: $relative"
        printf 'GOOD  %s\n' "$relative"
    done < "$ROOT/SHA256SUMS.txt"
    for relative in FLASH.bat scripts/menu.ps1 scripts/language.ps1 check-base.ps1 flash.ps1 flash.sh restore-super.ps1 restore-super.sh \
        scripts/common.ps1 scripts/common.sh scripts/builds.ps1 scripts/builds.sh scripts/prepare-super.sh images/recovery.img images/super.img.zst \
        images/vbmeta.img images/vbmeta_system.img tools/TWRP-FUXI-A17.img bin/platform-tools-windows/adb.exe \
        bin/platform-tools-windows/fastboot.exe bin/platform-tools-windows/zstd.exe bin/platform-tools-windows/AdbWinApi.dll \
        bin/platform-tools-windows/AdbWinUsbApi.dll bin/platform-tools-windows/NOTICE.txt \
        bin/platform-tools-windows/source.properties bin/platform-tools-windows/LICENSE-zstd.txt \
        firmware.conf prepare-payload.py scripts/payload.py PREPARE_PAYLOAD.bat; do
        [[ "$seen" == *$'\n'"$relative"$'\n'* ]] || fail "Required checksum entry is missing: $relative"
    done
    read_firmware_profile
    for relative in "${EXTRA_IMAGES[@]}"; do
        [[ "$seen" == *$'\n'"images/$relative.img"$'\n'* ]] || fail "Required checksum entry is missing: images/$relative.img"
    done
}

read_firmware_profile() {
    local line key value seen=$'\n' count=0 format='' expanded='' extra='' name
    REQUIRED_FIRMWARE='' FIRMWARE_NAME='' SUPER_SPARSE_BYTES='' SUPER_SHA256=''
    EXTRA_IMAGES=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^([a-z][a-z0-9_]*)=([A-Za-z0-9._,-]*)$ ]] || fail 'Invalid firmware.conf entry.'
        key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        [[ "$seen" != *$'\n'"$key"$'\n'* ]] || fail 'Duplicate firmware.conf key.'
        seen+="$key"$'\n'
        count=$((count + 1))
        case "$key" in
            format) format="$value" ;;
            name) FIRMWARE_NAME="$value" ;;
            base_firmware) REQUIRED_FIRMWARE="$value" ;;
            super_sparse_bytes) SUPER_SPARSE_BYTES="$value" ;;
            super_expanded_bytes) expanded="$value" ;;
            super_sha256) SUPER_SHA256="$value" ;;
            extra_images) extra="$value" ;;
            *) fail "Unknown firmware.conf key: $key" ;;
        esac
    done < "$ROOT/firmware.conf"
    [ "$count" -eq 7 ] && [ "$format" = 1 ] && [ "$expanded" = 11811160064 ] || fail 'Only the complete supported fuxi 11 GiB super profile is accepted.'
    [[ "$FIRMWARE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] &&
        [[ "$REQUIRED_FIRMWARE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$ ]] || fail 'Invalid firmware name or base firmware.'
    [[ "$SUPER_SPARSE_BYTES" =~ ^[1-9][0-9]{1,10}$ ]] &&
        [ "$SUPER_SPARSE_BYTES" -ge 28 ] && [ "$SUPER_SPARSE_BYTES" -le 12884901888 ] &&
        [[ "$SUPER_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid sparse image size or hash in firmware.conf.'
    if [ -n "$extra" ]; then
        [[ "$extra" =~ ^(boot|init_boot|vendor_boot|dtbo)(,(boot|init_boot|vendor_boot|dtbo))*$ ]] || fail 'Unsupported extra image.'
        IFS=, read -r -a EXTRA_IMAGES <<< "$extra"
        seen=$'\n'
        for name in "${EXTRA_IMAGES[@]}"; do
            [[ "$seen" != *$'\n'"$name"$'\n'* ]] || fail 'Duplicate extra image.'
            seen+="$name"$'\n'
        done
    fi
}

finish_session() {
    local code=$?
    trap - EXIT
    if [ "$LOCK_OWNED" = 1 ]; then
        rm -f "$ROOT/.installer.lock" || printf 'Could not remove .installer.lock; see README_RU.txt.\n' >&2
    fi
    exit "$code"
}

start_session() {
    (set -o noclobber; printf 'pid=%s operation=%s\n' "$$" "$1" > "$ROOT/.installer.lock") 2>/dev/null ||
        fail 'Cannot acquire .installer.lock. Another operation is running, a stale lock remains, or the folder is not writable. See README_RU.txt.'
    LOCK_OWNED=1
    trap finish_session EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$ROOT/logs" || fail 'Cannot create logs directory.'
    local log="$ROOT/logs/$(date +%Y%m%d-%H%M%S)-$$-$1.log"
    exec > >(tee -a "$log") 2>&1
    printf 'Session log: %s\n' "$log"
}

check_extra_images() {
    local name value size
    for name in "${EXTRA_IMAGES[@]}"; do
        value="$(get_fastboot_var "partition-size:${name}_a")" || return 1
        value="${value#0x}"
        [[ "$value" =~ ^[0-9a-f]{1,16}$ ]] || fail "Invalid partition size: ${name}_a"
        size="$(wc -c < "$IMAGES/$name.img")"
        [ "$((16#$value))" -ge "$size" ] || fail "Extra image exceeds the physical partition size: ${name}_a"
    done
}

check_required_images() {
    local name value size twrp_size
    for name in recovery vbmeta vbmeta_system; do
        value="$(get_fastboot_var "partition-size:${name}_a")" || return 1
        value="${value#0x}"
        [[ "$value" =~ ^[0-9a-f]{1,16}$ ]] || fail "Invalid partition size: ${name}_a"
        size="$(wc -c < "$IMAGES/$name.img")"
        if [ "$name" = recovery ]; then
            twrp_size="$(wc -c < "$TOOLS/TWRP-FUXI-A17.img")"
            [ "$size" -ge "$twrp_size" ] || size="$twrp_size"
        fi
        [ "$((16#$value))" -ge "$size" ] || fail "Required image exceeds the physical partition size: ${name}_a"
    done
}

find_tools() {
    FASTBOOT="${FASTBOOT:-$(command -v fastboot || true)}"
    ADB="${ADB:-$(command -v adb || true)}"
    [ -n "$FASTBOOT" ] && [ -x "$FASTBOOT" ] || fail 'Install Android platform-tools; fastboot is missing or not executable.'
    [ -n "$ADB" ] && [ -x "$ADB" ] || fail 'Install Android platform-tools; adb is missing or not executable.'
    if [ "${NEED_ZSTD:-0}" = 1 ]; then
        ZSTD="${ZSTD:-$(command -v zstd || true)}"
        [ -n "$ZSTD" ] && [ -x "$ZSTD" ] || fail 'Install zstd; the decompressor is missing or not executable.'
    fi
}

invoke_fastboot() { "$FASTBOOT" -s "$SERIAL" "$@" || fail "fastboot failed: $*"; }
invoke_adb() { "$ADB" -s "$SERIAL" "$@" || fail "adb failed: $*"; }

get_fastboot_var() {
    local output value
    output="$("$FASTBOOT" -s "$SERIAL" getvar "$1" 2>&1)" || fail "fastboot getvar $1 failed: $output"
    value="$(printf '%s\n' "$output" | tr -d '\r' | awk -v key="$1:" '
        { sub(/^\(bootloader\)[[:space:]]*/, ""); sub(/^bootloader:[[:space:]]*/, "") }
        index($0, key) == 1 {
            value = substr($0, length(key) + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value == "" || value ~ /[[:space:]]/) exit 1
            count++; result = tolower(value)
        }
        END { if (count != 1) exit 1; print result }
    ')" || fail "Could not read a single fastboot variable '$1': $output"
    printf '%s\n' "$value"
}

get_super_size() {
    local value
    value="$(get_fastboot_var partition-size:super)" || return 1
    value="${value#0x}"
    [[ "$value" =~ ^[0-9a-f]{1,16}$ ]] || fail "Invalid super size: $value"
    printf '0x%x\n' "$((16#$value))"
}

get_fastboot_devices() {
    local output
    output="$("$FASTBOOT" devices 2>&1)" || fail "fastboot devices failed: $output"
    printf '%s\n' "$output" | tr -d '\r' | awk '
        NF == 0 { next }
        NF == 2 && $2 == "fastboot" { print $1; next }
        { exit 1 }
    ' || fail 'Unexpected fastboot devices output.'
}

wait_fastboot() {
    local devs count i
    printf 'Waiting for the selected device in bootloader fastboot...\n'
    for ((i=0; i<120; i++)); do
        devs="$(get_fastboot_devices)" || return 1
        count="$(printf '%s\n' "$devs" | awk 'NF {n++} END {print n+0}')"
        [ "$count" -le 1 ] || fail 'Disconnect other fastboot devices.'
        if [ "$devs" = "$SERIAL" ]; then return 0; fi
        sleep 1
    done
    fail 'Timed out waiting for the selected device in fastboot.'
}

wait_adb() {
    local state i
    printf 'Waiting for the selected device in TWRP recovery...\n'
    for ((i=0; i<180; i++)); do
        state="$("$ADB" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r\n')" || state=''
        if [ "$state" = device ] || [ "$state" = recovery ]; then return 0; fi
        sleep 1
    done
    fail 'Timed out waiting for recovery ADB.'
}

check_bootloader() {
    local product slot unlocked userspace
    product="$(get_fastboot_var product)" || return 1
    [ "$product" = fuxi ] || fail "Connected device is not Xiaomi 13 fuxi: $product"
    slot="$(get_fastboot_var current-slot)" || return 1
    [ "${slot#_}" = a ] || fail 'Slot A must already be active. Select the correct starting firmware and slot manually.'
    unlocked="$(get_fastboot_var unlocked)" || return 1
    [ "$unlocked" = yes ] || fail 'The bootloader is locked.'
    userspace="$(get_fastboot_var is-userspace)" || return 1
    [ "$userspace" = no ] || fail 'Bootloader fastboot is required. Unknown mode and fastbootd are refused.'
}

connect_device() {
    local fb adb_output adb_devices fb_count adb_count state product
    "$ADB" start-server >/dev/null 2>&1 || fail 'adb start-server failed.'
    fb="$(get_fastboot_devices)" || return 1
    adb_output="$("$ADB" devices 2>&1)" || fail 'adb devices failed.'
    adb_devices="$(printf '%s\n' "$adb_output" | tr -d '\r' | awk '$2 ~ /^(device|recovery|offline|unauthorized|sideload)$/ {print $1, $2}')"
    fb_count="$(printf '%s\n' "$fb" | awk 'NF {n++} END {print n+0}')"
    adb_count="$(printf '%s\n' "$adb_devices" | awk 'NF {n++} END {print n+0}')"
    [ "$((fb_count + adb_count))" -eq 1 ] || fail 'Connect exactly one device, in bootloader fastboot or authorized ADB.'
    if [ "$fb_count" -eq 0 ]; then
        read -r SERIAL state <<< "$adb_devices"
        [ "$state" = device ] || [ "$state" = recovery ] || fail 'Authorize ADB or enter bootloader fastboot manually.'
        product="$(invoke_adb shell getprop ro.product.device | tr -d '\r\n')" || return 1
        [ "$product" = fuxi ] || fail "Connected ADB device is not fuxi: $product"
        invoke_adb reboot bootloader
        wait_fastboot
    else
        SERIAL="$fb"
    fi
    check_bootloader
}

start_resize_recovery() {
    check_bootloader
    invoke_fastboot --disable-verity --disable-verification flash vbmeta_a "$IMAGES/vbmeta.img"
    invoke_fastboot --disable-verity --disable-verification flash vbmeta_system_a "$IMAGES/vbmeta_system.img"
    invoke_fastboot flash recovery_a "$TOOLS/TWRP-FUXI-A17.img"
    invoke_fastboot reboot recovery
    wait_adb
    local product twrp remote backup
    product="$(invoke_adb shell getprop ro.product.device | tr -d '\r\n')" || return 1
    [ "$product" = fuxi ] || fail 'Recovery does not report fuxi.'
    twrp="$(invoke_adb shell getprop ro.twrp.version.skkk.code | tr -d '\r\n')" || return 1
    [ -n "$twrp" ] || fail 'The bundled TWRP did not start.'
    invoke_adb push "$SCRIPTS/prepare-super.sh" /tmp/prepare-super.sh
    invoke_adb shell 'sh /tmp/prepare-super.sh audit'
    remote="$(invoke_adb shell 'sha256sum /tmp/fuxi-gpt-before.bin' | tr -d '\r')" || return 1
    [[ "$remote" =~ ^([0-9a-f]{64})[[:space:]]+/tmp/fuxi-gpt-before.bin[[:space:]]*$ ]] || fail 'Could not read the GPT backup checksum.'
    BACKUP_HASH="${BASH_REMATCH[1]}"
    mkdir -p "$ROOT/backups" || fail 'Cannot create the computer backup directory.'
    backup="$(mktemp "$ROOT/backups/fuxi-gpt-XXXXXXXX.bin")" || fail 'Cannot create the computer backup file.'
    invoke_adb pull /tmp/fuxi-gpt-before.bin "$backup"
    [ -s "$backup" ] || fail 'The GPT backup was not saved on the computer.'
    [ "$(hash_file "$backup")" = "$BACKUP_HASH" ] || fail 'The computer GPT backup does not match the recovery backup.'
    printf '%s\n' "$BACKUP_HASH" > "$backup.sha256" || fail 'Cannot save the backup checksum.'
    printf 'Verified GPT backup saved: %s\n' "$backup"
}

resize_super() {
    local confirmation expected
    if [ "$1" = apply ]; then confirmation=ERASE_AND_RESIZE; expected="$EXPANDED_SUPER"
    else confirmation=RESTORE_STOCK_SUPER; expected="$STOCK_SUPER"; fi
    invoke_adb shell "FUXI_CONFIRM=$confirmation FUXI_BACKUP_SHA256=$BACKUP_HASH sh /tmp/prepare-super.sh $1"
    invoke_adb reboot bootloader
    wait_fastboot
    check_bootloader
    [ "$(get_super_size)" = "$expected" ] || fail "The requested physical super size $expected was not detected after reboot."
}
