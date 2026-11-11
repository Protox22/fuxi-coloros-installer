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
DEVICE_LOCK=''
DEVICE_LOCK_OWNED=0
RESTORE_STATE=''
ALLOWED_BOOT_SLOTS='a'
EXPECTED_BOOT_SLOT=''
CHECKED_BOOT_SLOT=''
SESSION_LOG=''
COMPACT="${COMPACT:-0}"
source "$SCRIPTS/language.sh"
source "$SCRIPTS/status.sh"

step() { printf '\n  > %s\n' "$(get_text "$@")"; }

show_error_hint() {
    local key=hintStopped
    case "$*" in
        *SHA-256*|*checksum*|*missing*file*|*firmware.conf*) key=hintFiles ;;
        *installer.lock*) key=hintLock ;;
        *space*|*GiB\ free*) key=hintSpace ;;
        *slot*|*Slot*) key=hintSlot ;;
        *missing*executable*|*Install*|*required\ tool*) key=hintTools ;;
        *device*|*ADB*|*locked*|*permissions*|*Timed\ out*|*fastboot\ devices*) key=hintUsb ;;
    esac
    get_text "$key" >&2
    record_event error "$key"
}

fail() {
    printf '\n%s: %s\n' "$(get_text error)" "$*" >&2
    show_error_hint "$*" || printf 'Could not write the error journal.\n' >&2
    [ -z "$SESSION_LOG" ] || get_text logPath "$SESSION_LOG" >&2
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
        printf '%s [y/N]: ' "$1"
        read -r answer || return 1
        answer="${answer#"${answer%%[![:space:]]*}"}"
        answer="${answer%"${answer##*[![:space:]]}"}"
        case "$answer" in
            y|Y) return 0 ;;
            n|N|'') return 1 ;;
            *) get_text invalidYesNo ;;
        esac
    done
}

verify_payload() {
    record_event phase.verify started
    local allow_missing_super="${1:-0}" line expected relative actual component prefix count=0 total seen=$'\n' canonical_seen=$'\n' canonical
    [ -f "$ROOT/SHA256SUMS.txt" ] || fail 'SHA256SUMS.txt is missing.'
    total="$(awk 'END {print NR}' "$ROOT/SHA256SUMS.txt")"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^([0-9a-fA-F]{64})\ \ (\./)?([A-Za-z0-9_./-]+)$ ]] || fail "Invalid checksum entry: $line"
        expected="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        relative="${BASH_REMATCH[3]}"
        canonical="${relative,,}"
        case "$relative" in /*|*/|*//*|.|..|./*|../*|*/./*|*/../*|*/.|*/..) fail "Unsafe checksum path: $relative" ;; esac
        [[ "$seen" != *$'\n'"$relative"$'\n'* ]] || fail "Duplicate checksum path: $relative"
        [[ "$canonical_seen" != *$'\n'"$canonical"$'\n'* ]] || fail "Duplicate checksum path: $relative"
        seen+="$relative"$'\n'
        canonical_seen+="$canonical"$'\n'
        prefix="$ROOT"
        IFS=/ read -r -a components <<< "$relative"
        for component in "${components[@]}"; do
            prefix="$prefix/$component"
            [ ! -L "$prefix" ] || fail "Symlink in checksum path: $relative"
        done
        if [ "${DIAGNOSTICS_ONLY:-0}" = 1 ]; then
            case "$relative" in images/*|tools/*|bin/*) continue ;; esac
        fi
        if [ ! -f "$ROOT/$relative" ]; then
            if [[ ( "${INSTALLER_ONLY:-0}" = 1 && ( "$relative" = images/* || "$relative" = tools/* ) ) ||
                  ( "$allow_missing_super" = 1 && "$relative" = images/super.img.zst ) ]]; then
                printf 'OMITTED  %s\n' "$relative"
                continue
            fi
            fail "Required release file is missing: $relative"
        fi
        count=$((count + 1))
        [ "$COMPACT" = 0 ] || get_text checkingFile "$count" "$total" "$relative"
        actual="$(hash_file "$ROOT/$relative")" || fail "Cannot hash: $relative"
        [ "$actual" = "$expected" ] || fail "SHA-256 mismatch: $relative"
        [ "$COMPACT" = 1 ] || printf 'GOOD  %s\n' "$relative"
    done < "$ROOT/SHA256SUMS.txt"
    for relative in scripts/status.ps1 scripts/status.sh support-report.ps1 support-report.sh FLASH.bat START.sh QUICK_START.txt scripts/menu.ps1 scripts/menu.sh scripts/language.ps1 scripts/language.sh scripts/process.ps1 check-base.ps1 check-base.sh flash.ps1 flash.sh restore-super.ps1 restore-super.sh \
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
    local code=${1:-$?}
    trap - EXIT
    # Cleanup must run even when the journal, console or an earlier cleanup fails.
    set +e
    case "$code" in
        0) record_event result finished ;;
        2) record_event result cancelled ;;
        *) show_failure_state ;;
    esac || printf 'Could not write the final session status.\n' >&2
    if [ -n "$SUPER_IMAGE" ]; then
        # Only the exact file/directory created by mktemp in this process.
        if rm -f -- "$SUPER_IMAGE" && rmdir -- "$(dirname "$SUPER_IMAGE")"; then get_text tempRemoved
        else printf 'Temporary image cleanup failed: %s\n' "$SUPER_IMAGE" >&2; fi
    fi
    [ "$code" = 0 ] || [ -z "$SESSION_LOG" ] || get_text logPath "$SESSION_LOG" >&2
    if [ "$LOCK_OWNED" = 1 ]; then
        rm -f "$ROOT/.installer.lock" || printf 'Could not remove .installer.lock; see README_RU.txt.\n' >&2
    fi
    # The device stays reserved until all other cleanup has been attempted.
    if [ "$DEVICE_LOCK_OWNED" = 1 ]; then
        rm -f -- "$DEVICE_LOCK" || printf 'Could not remove device lock: %s\n' "$DEVICE_LOCK" >&2
    fi
    exit "$code"
}

acquire_device_lock() {
    local directory key
    [ "$DEVICE_LOCK_OWNED" = 0 ] || fail 'A device lock is already held.'
    [ -n "$SERIAL" ] || fail 'Cannot lock a device without its serial.'
    if [ "${OS:-}" = Windows_NT ]; then
        [ -n "${LOCALAPPDATA:-}" ] || fail 'LOCALAPPDATA is required for the shared device lock.'
        directory="$(cygpath -u "$LOCALAPPDATA")/FuxiInstaller/devices"
    else
        directory="${XDG_STATE_HOME:-${HOME:?HOME is required}/.local/state}/FuxiInstaller/devices"
    fi
    (umask 077; mkdir -p -- "$directory") || fail 'Cannot create the shared device state directory.'
    [ ! -L "$directory" ] && [ -d "$directory" ] || fail 'Unsafe device state directory.'
    if command -v sha256sum >/dev/null 2>&1; then
        key="$(printf '%s' "$SERIAL" | sha256sum | awk '{print $1}')"
    else
        key="$(printf '%s' "$SERIAL" | shasum -a 256 | awk '{print $1}')"
    fi
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || fail 'Cannot compute the device lock key.'
    DEVICE_LOCK="$directory/$key.lock"
    RESTORE_STATE="$directory/$key.restore-state"
    # Same CreateNew protocol as PowerShell, including Git Bash on Windows.
    (umask 077; set -o noclobber; printf 'pid=%s\n' "$$" > "$DEVICE_LOCK") 2>/dev/null ||
        fail "$(get_text deviceBusy "$DEVICE_LOCK")"
    DEVICE_LOCK_OWNED=1
}

write_restore_state() {
    local temporary
    [ "$DEVICE_LOCK_OWNED" = 1 ] && [ -n "$RESTORE_STATE" ] || fail 'Restore state requires the device lock.'
    [ ! -L "$RESTORE_STATE" ] || fail 'Linked restore state is not supported.'
    [ ! -e "$RESTORE_STATE" ] || [ -f "$RESTORE_STATE" ] || fail 'Invalid restore state file.'
    case "$1" in gpt.restore|flash.recovery_a|erase.userdata|erase.metadata) ;; *) fail 'Invalid restore stage.' ;; esac
    temporary="$(mktemp "$RESTORE_STATE.XXXXXXXX")" || fail 'Cannot create restore state.'
    if ! { printf '%s\n' "$1" > "$temporary" && mv -fT -- "$temporary" "$RESTORE_STATE"; }; then
        rm -f -- "$temporary" || true
        fail 'Cannot save restore state; no further device commands will run.'
    fi
}

check_incomplete_restore() {
    local stage pending
    [ -e "$RESTORE_STATE" ] || [ -L "$RESTORE_STATE" ] || return 0
    stage=''
    if [ -f "$RESTORE_STATE" ] && [ ! -L "$RESTORE_STATE" ]; then stage="$(cat "$RESTORE_STATE")" || stage=''; fi
    case "$stage" in
        gpt.restore) pending='gpt.restore, flash.recovery_a, erase.userdata, erase.metadata' ;;
        flash.recovery_a) pending='flash.recovery_a, erase.userdata, erase.metadata' ;;
        erase.userdata) pending='erase.userdata, erase.metadata' ;;
        erase.metadata) pending='erase.metadata' ;;
        *) pending='UNKNOWN: gpt.restore, flash.recovery_a, erase.userdata, erase.metadata' ;;
    esac
    fail "$(get_text restoreIncomplete "$pending" "$RESTORE_STATE")"
}

clear_restore_state() {
    rm -f -- "$RESTORE_STATE" || fail 'Cannot clear completed restore state.'
}

start_session() {
    (set -o noclobber; printf 'pid=%s operation=%s\n' "$$" "$1" > "$ROOT/.installer.lock") 2>/dev/null ||
        fail 'Cannot acquire .installer.lock. Another operation is running, a stale lock remains, or the folder is not writable. See README_RU.txt.'
    LOCK_OWNED=1
    trap finish_session EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$ROOT/logs" || fail 'Cannot create logs directory.'
    SESSION_LOG="$ROOT/logs/$(date +%Y%m%d-%H%M%S)-$$-$1.log"
    EVENT_FILE="$SESSION_LOG.events.tsv"
    record_event "session.$1" started
    exec > >(tee -a "$SESSION_LOG") 2>&1
    get_text logPath "$SESSION_LOG"
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
    local resize_slot="${1:-}" slot="${1:-a}" name partition value size image
    for name in recovery vbmeta vbmeta_system; do
        partition="${name}_$slot"
        value="$(get_fastboot_var "partition-size:$partition")" || return 1
        value="${value#0x}"
        [[ "$value" =~ ^[0-9a-f]{1,16}$ ]] || fail "Invalid partition size: $partition"
        if [ -n "$resize_slot" ] && [ "$name" = recovery ]; then
            image="$TOOLS/TWRP-FUXI-A17.img"
        else
            image="$IMAGES/$name.img"
        fi
        size="$(wc -c < "$image")"
        [ "$((16#$value))" -ge "$size" ] || fail "Required image exceeds the physical partition size: $partition"
    done
}

find_tools() {
    command -v timeout >/dev/null 2>&1 || fail 'The required tool timeout (GNU coreutils) is missing.'
    FASTBOOT="${FASTBOOT:-$(command -v fastboot || true)}"
    ADB="${ADB:-$(command -v adb || true)}"
    [ -n "$FASTBOOT" ] && [ -x "$FASTBOOT" ] || fail 'Install Android platform-tools; fastboot is missing or not executable.'
    [ -n "$ADB" ] && [ -x "$ADB" ] || fail 'Install Android platform-tools; adb is missing or not executable.'
    if [ "${NEED_ZSTD:-0}" = 1 ]; then
        ZSTD="${ZSTD:-$(command -v zstd || true)}"
        [ -n "$ZSTD" ] && [ -x "$ZSTD" ] || fail 'Install zstd; the decompressor is missing or not executable.'
    fi
}

invoke_fastboot() {
    local action
    action="$(mutation_action fastboot "$@")"
    [ -z "$action" ] || record_event "$action" started
    printf '> fastboot %s\n' "$*"
    timeout --foreground --kill-after=5 1200 "$FASTBOOT" -s "$SERIAL" "$@" || fail "fastboot failed or timed out: $*"
    [ -z "$action" ] || record_event "$action" done
}
invoke_adb() {
    local action
    action="$(mutation_action adb "$@")"
    [ -z "$action" ] || record_event "$action" started
    timeout --foreground --kill-after=5 300 "$ADB" -s "$SERIAL" "$@" || fail "adb failed or timed out: $*"
    [ -z "$action" ] || record_event "$action" done
}

get_fastboot_var() {
    local output value
    output="$(timeout --foreground --kill-after=5 15 "$FASTBOOT" -s "$SERIAL" getvar "$1" 2>&1)" || fail "fastboot getvar $1 failed or timed out: $output"
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
    output="$(timeout --foreground --kill-after=5 15 "$FASTBOOT" devices 2>&1)" || fail "fastboot devices failed: $output"
    printf '%s\n' "$output" | tr -d '\r' | awk '
        NF == 0 { next }
        NF == 2 && $2 == "fastboot" { print $1; next }
        { exit 1 }
    ' || fail 'Unexpected fastboot devices output.'
}

wait_fastboot() {
    local devs count deadline=$((SECONDS + 120))
    printf 'Waiting for the selected device in bootloader fastboot...\n'
    while [ "$SECONDS" -lt "$deadline" ]; do
        devs="$(get_fastboot_devices)" || return 1
        count="$(printf '%s\n' "$devs" | awk 'NF {n++} END {print n+0}')"
        [ "$count" -le 1 ] || fail 'Disconnect other fastboot devices.'
        if [ "$devs" = "$SERIAL" ]; then return 0; fi
        sleep 1
    done
    fail 'Timed out waiting for the selected device in fastboot.'
}

wait_adb() {
    local state deadline=$((SECONDS + 180))
    printf 'Waiting for the selected device in TWRP recovery...\n'
    while [ "$SECONDS" -lt "$deadline" ]; do
        state="$(timeout --foreground --kill-after=5 5 "$ADB" -s "$SERIAL" get-state 2>/dev/null | tr -d '\r\n')" || state=''
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
    slot="${slot#_}"
    case " $ALLOWED_BOOT_SLOTS " in *" $slot "*) ;; *) fail "Unsupported active slot '$slot'. Allowed: $ALLOWED_BOOT_SLOTS" ;; esac
    [ -z "$EXPECTED_BOOT_SLOT" ] || [ "$slot" = "$EXPECTED_BOOT_SLOT" ] || fail "Active slot changed unexpectedly: expected $EXPECTED_BOOT_SLOT, got $slot."
    CHECKED_BOOT_SLOT="$slot"
    unlocked="$(get_fastboot_var unlocked)" || return 1
    [ "$unlocked" = yes ] || fail 'The bootloader is locked.'
    userspace="$(get_fastboot_var is-userspace)" || return 1
    [ "$userspace" = no ] || fail 'Bootloader fastboot is required. Unknown mode and fastbootd are refused.'
}

connect_device() {
    record_event phase.device started
    local fb adb_output adb_devices fb_count adb_count state product
    timeout --foreground --kill-after=5 15 "$ADB" start-server >/dev/null 2>&1 || fail 'adb start-server failed.'
    fb="$(get_fastboot_devices)" || return 1
    adb_devices="$(get_adb_devices)" || return 1
    fb_count="$(printf '%s\n' "$fb" | awk 'NF {n++} END {print n+0}')"
    adb_count="$(printf '%s\n' "$adb_devices" | awk 'NF {n++} END {print n+0}')"
    [ "$((fb_count + adb_count))" -eq 1 ] || fail 'Connect exactly one device, in bootloader fastboot or authorized ADB.'
    if [ "$fb_count" -eq 0 ]; then
        read -r SERIAL state <<< "$adb_devices"
        [ "$state" = device ] || [ "$state" = recovery ] || fail 'Authorize ADB or enter bootloader fastboot manually.'
        product="$(invoke_adb shell getprop ro.product.device | tr -d '\r\n')" || return 1
        [ "$product" = fuxi ] || fail "Connected ADB device is not fuxi: $product"
        acquire_device_lock
        invoke_adb reboot bootloader
        wait_fastboot
    else
        SERIAL="$fb"
        acquire_device_lock
    fi
    check_bootloader
}

get_adb_devices() {
    local output
    output="$(timeout --foreground --kill-after=5 15 "$ADB" devices 2>&1)" || fail "adb devices failed: $output"
    printf '%s\n' "$output" | tr -d '\r' | awk '
        /^List of devices attached[[:space:]]*$/ || /^\* daemon/ || NF == 0 { next }
        NF == 2 && $2 ~ /^(device|recovery|offline|unauthorized|sideload)$/ {print $1, $2; next}
        { exit 1 }
    ' || fail 'Unexpected adb devices output (check USB permissions).'
}

start_resize_recovery() {
    check_bootloader
    local slot="$CHECKED_BOOT_SLOT"
    invoke_fastboot --disable-verity --disable-verification flash "vbmeta_$slot" "$IMAGES/vbmeta.img"
    invoke_fastboot --disable-verity --disable-verification flash "vbmeta_system_$slot" "$IMAGES/vbmeta_system.img"
    invoke_fastboot flash "recovery_$slot" "$TOOLS/TWRP-FUXI-A17.img"
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
    get_text backupPath "$backup"
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
