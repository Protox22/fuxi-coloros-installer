#!/system/bin/sh
# GPT preflight and 9 GiB <-> 11 GiB conversion for the exact supported fuxi geometry.
# This script is executed only inside the bundled TWRP recovery.
set -eu
export LC_ALL=C
umask 077

DISK=/dev/block/sda
SGDISK=/system/bin/sgdisk
BACKUP=/tmp/fuxi-gpt-before.bin
CURRENT=/tmp/fuxi-gpt-current.bin

EXPECTED_SECTOR_SIZE=4096
SUPER_START=854080
STOCK_SUPER_END=3213375
EXPANDED_SUPER_END=3737663
STOCK_USERDATA_START=3213376
EXPANDED_USERDATA_START=3737664
EXPECTED_SUPER_TYPE=89A12DE1-5E41-4CB3-8B4C-B1441EB5DA38
EXPECTED_USERDATA_TYPE=1B81E7E6-F50D-419B-A739-2AEEF8DA3335
MIN_DISK_BYTES=68719476736 # 64 GiB minimum disk size

fail() {
    echo "ERROR: $*" >&2
    if [ -n "${gpt_table:-}" ]; then
        printf 'Observed GPT table (read-only):\n%s\n' "$gpt_table" >&2
    fi
    exit 1
}

need() {
    [ -x "$1" ] || fail "Required recovery tool is missing: $1"
}

partition_info() {
    "$SGDISK" --info="$1" "$DISK"
}

first_word_after_colon() {
    sed -n "s/^$1:[[:space:]]*//p" | sed -n '1{s/[[:space:]].*$//;p;}'
}

name_from_info() {
    sed -n "s/^Partition name: '\(.*\)'/\1/p" | sed -n '1p'
}

resolve_partition() {
    partition_name="$1"
    expected_block="$2"
    [ -b "$expected_block" ] || fail "Expected $partition_name block device is missing: $expected_block"
    expected_id="$(stat -L -c '%t:%T' "$expected_block")" || fail "Cannot identify $expected_block"
    printf '%s\n' "$expected_id" | grep -Eq '^[0-9a-fA-F]+:[0-9a-fA-F]+$' || fail "Invalid block identity for $expected_block"

    # Recovery builds can expose either by-name directory, or no by-name links.
    # Compare device numbers, not path spelling. Any conflicting alias is fatal.
    # The GPT name, GUIDs and exact sectors are independently checked below,
    # including when only the physical block node is available.
    for directory in /dev/block/by-name /dev/block/bootdevice/by-name; do
        alias_block="$directory/$partition_name"
        if [ -e "$alias_block" ] || [ -L "$alias_block" ]; then
            resolved_block="$(readlink -f "$alias_block" 2>/dev/null)" || fail "Cannot resolve $alias_block"
            [ -b "$alias_block" ] || fail "$alias_block -> $resolved_block is not a usable block device"
            alias_id="$(stat -L -c '%t:%T' "$alias_block")" || fail "Cannot identify $alias_block"
            [ "$alias_id" = "$expected_id" ] || \
                fail "Unsupported $partition_name mapping: $alias_block -> $resolved_block (device $alias_id); expected $expected_block (device $expected_id). Save the full log."
        fi
    done
    printf '%s\n' "$expected_block"
}

read_layout() {
    need "$SGDISK"
    [ -b "$DISK" ] || fail "Expected block device is missing: $DISK"
    [ "$(getprop ro.product.device)" = fuxi ] || fail 'Recovery device is not fuxi'
    [ -n "$(getprop ro.twrp.version.skkk.code)" ] || fail 'The bundled TWRP is required'
    gpt_table="$("$SGDISK" --print "$DISK")" || fail 'Cannot read the GPT table'
    super_number="$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF == "super" {print $1}')"
    userdata_number="$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF == "userdata" {print $1}')"
    # Only these two independently known index/start combinations are accepted.
    # GPT names alone must never authorize arbitrary geometry or new partitions.
    case "$super_number:$userdata_number" in
        32:33)
            SUPER_START=854080
            STOCK_SUPER_END=3213375
            EXPANDED_SUPER_END=3737663
            STOCK_USERDATA_START=3213376
            EXPANDED_USERDATA_START=3737664
            ;;
        31:32)
            SUPER_START=751680
            STOCK_SUPER_END=3110975
            EXPANDED_SUPER_END=3635263
            STOCK_USERDATA_START=3110976
            EXPANDED_USERDATA_START=3635264
            ;;
        *) fail "Unsupported or ambiguous GPT entries: super=$super_number userdata=$userdata_number" ;;
    esac
    SUPER_BLOCK="$(resolve_partition super "${DISK}${super_number}")" || exit 1
    USERDATA_BLOCK="$(resolve_partition userdata "${DISK}${userdata_number}")" || exit 1

    sector_size="$(cat /sys/class/block/sda/queue/logical_block_size)"
    disk_bytes="$(blockdev --getsize64 "$DISK")"
    case "$disk_bytes" in ''|*[!0-9]*) fail 'Invalid disk size' ;; esac
    [ "$sector_size" = "$EXPECTED_SECTOR_SIZE" ] || \
        fail "Unexpected logical sector size: $sector_size"
    # Android mksh shell arithmetic/test integers are 32-bit, even on arm64.
    # Keep large byte/sector values in awk's exact integer range, not $((...)).
    awk -v bytes="$disk_bytes" -v minimum="$MIN_DISK_BYTES" \
        'BEGIN { exit !(bytes + 0 >= minimum + 0) }' || \
        fail "Storage size is too small: $disk_bytes bytes (minimum required: $MIN_DISK_BYTES bytes)."

    disk_sectors="$(awk -v bytes="$disk_bytes" -v sector="$EXPECTED_SECTOR_SIZE" '
        BEGIN {
            if (bytes + 0 > 9007199254740991 || bytes % sector != 0) exit 1
            printf "%.0f\n", bytes / sector
        }
    ')" || fail 'Disk size is not sector-aligned or exceeds the exact supported range'

    info_super="$(partition_info "$super_number")"
    info_userdata="$(partition_info "$userdata_number")"

    super_type="$(printf '%s\n' "$info_super" | first_word_after_colon 'Partition GUID code')"
    super_guid="$(printf '%s\n' "$info_super" | first_word_after_colon 'Partition unique GUID')"
    super_first="$(printf '%s\n' "$info_super" | first_word_after_colon 'First sector')"
    super_last="$(printf '%s\n' "$info_super" | first_word_after_colon 'Last sector')"
    super_attrs="$(printf '%s\n' "$info_super" | first_word_after_colon 'Attribute flags')"
    super_name="$(printf '%s\n' "$info_super" | name_from_info)"

    userdata_type="$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Partition GUID code')"
    userdata_guid="$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Partition unique GUID')"
    userdata_first="$(printf '%s\n' "$info_userdata" | first_word_after_colon 'First sector')"
    userdata_last="$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Last sector')"
    userdata_attrs="$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Attribute flags')"
    userdata_name="$(printf '%s\n' "$info_userdata" | name_from_info)"

    for number in "$super_first" "$super_last" "$userdata_first" "$userdata_last"; do
        case "$number" in ''|*[!0-9]*) fail 'Invalid partition sector number' ;; esac
    done
    for guid in "$super_guid" "$userdata_guid"; do
        printf '%s\n' "$guid" | grep -Eq '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$' || fail 'Invalid partition GUID'
    done

    [ "$super_name" = super ] || fail "Partition $super_number is not named super"
    [ "$userdata_name" = userdata ] || fail "Partition $userdata_number is not named userdata"
    [ "$super_type" = "$EXPECTED_SUPER_TYPE" ] || fail "Unexpected super type GUID: $super_type"
    [ "$userdata_type" = "$EXPECTED_USERDATA_TYPE" ] || fail "Unexpected userdata type GUID: $userdata_type"
    [ "$super_first" = "$SUPER_START" ] || fail "Unexpected super start sector: $super_first"
    [ "$super_attrs" = 0000000000000000 ] || fail "Unexpected super attributes: $super_attrs"
    [ "$userdata_attrs" = 0000000000000000 ] || fail "Unexpected userdata attributes: $userdata_attrs"
    [ -n "$super_guid" ] || fail "Could not read the super unique GUID"
    [ -n "$userdata_guid" ] || fail "Could not read the userdata unique GUID"
    awk -v last="$userdata_last" -v first="$EXPANDED_USERDATA_START" \
        'BEGIN { exit !(last + 0 > first + 0) }' || fail 'userdata is too small'
    awk -v last="$userdata_last" -v sectors="$disk_sectors" \
        'BEGIN { exit !(last + 0 < sectors - 1) }' || fail 'userdata exceeds disk bounds'

    if [ "$super_last" = "$STOCK_SUPER_END" ] && \
       [ "$userdata_first" = "$STOCK_USERDATA_START" ]; then
        layout=stock
    elif [ "$super_last" = "$EXPANDED_SUPER_END" ] && \
         [ "$userdata_first" = "$EXPANDED_USERDATA_START" ]; then
        layout=expanded
    else
        fail "Unsupported super/userdata boundary: super ends at $super_last, userdata starts at $userdata_first"
    fi
}

write_backup() {
    rm -f "$BACKUP"
    "$SGDISK" --backup="$BACKUP" "$DISK"
    [ -s "$BACKUP" ] || fail "GPT backup was not created"
    echo "GPT backup: $BACKUP"
    sha256sum "$BACKUP"
}

verify_gpt() {
    result="$("$SGDISK" --verify "$DISK")" || fail 'GPT verification command failed'
    printf '%s\n' "$result"
    # sgdisk can return zero even when --verify reports damaged GPT structures.
    printf '%s\n' "$result" | grep -q '^No problems found\.' || fail 'GPT verification reported problems'
}

check_saved_backup() {
    [ -s "$BACKUP" ] || fail 'Run audit and save the GPT backup on the computer first'
    hash="${FUXI_BACKUP_SHA256:-}"
    [ "${#hash}" -eq 64 ] || fail 'Missing verified computer backup checksum'
    case "$hash" in *[!0-9a-f]*) fail 'Invalid backup checksum' ;; esac
    [ "$(sha256sum "$BACKUP" | awk '{print $1}')" = "$hash" ] || fail 'The recovery GPT backup changed after audit'
    rm -f "$CURRENT"
    "$SGDISK" --backup="$CURRENT" "$DISK"
    [ -s "$CURRENT" ] || fail 'Could not create a fresh GPT comparison copy'
    cmp "$BACKUP" "$CURRENT" >/dev/null 2>&1 || fail 'GPT changed after audit; run audit and save a new backup'
}

unmount_partitions() {
    for point in /sdcard /cache /data /metadata /system_root /system /vendor /product /system_ext /odm /vendor_dlkm /odm_dlkm; do
        if awk -v point="$point" '$2 == point {found=1} END {exit !found}' /proc/mounts; then
            umount "$point" || fail "Cannot unmount $point; GPT was not changed"
        fi
    done
    remaining="$(awk '$1 ~ /^\/dev\/block\// {print $2}' /proc/mounts)"
    [ -z "$remaining" ] || fail "Block-backed mounts remain; unmount them before retrying: $remaining"
}

print_summary() {
    echo 'Device: Xiaomi 13 fuxi, exact supported partition geometry'
    echo "Disk bytes: $disk_bytes"
    echo "Disk sectors: $disk_sectors"
    echo "Logical sector size: $sector_size"
    echo "Current layout: $layout"
    echo "super GPT entry: $super_number; block: $SUPER_BLOCK"
    echo "userdata GPT entry: $userdata_number; block: $USERDATA_BLOCK"
    echo "super: $super_first-$super_last"
    echo "userdata: $userdata_first-$userdata_last"
}

mode="${1:-audit}"
case "$mode" in audit|apply|verify|restore) ;; *) fail "Usage: $0 audit|apply|verify|restore" ;; esac
for tool in blockdev sha256sum cmp readlink stat awk sed grep umount sync getprop; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required recovery tool is missing: $tool"
done
read_layout
verify_gpt
print_summary

case "$mode" in
    audit)
        write_backup
        ;;
    verify)
        [ "$layout" = expanded ] || fail "super is not expanded"
        [ "$(blockdev --getsize64 "$SUPER_BLOCK")" = 11811160064 ] || \
            fail "The live super block device is not 11 GiB"
        echo "Expanded super layout verified."
        ;;
    apply)
        [ "${FUXI_CONFIRM:-}" = ERASE_AND_RESIZE ] || \
            fail "Missing destructive-operation confirmation"
        check_saved_backup
        if [ "$layout" = expanded ]; then
            echo "super is already 11 GiB; no GPT write is needed."
            exit 0
        fi
        unmount_partitions
        saved_userdata_last="$userdata_last"
        "$SGDISK" --set-alignment=1 \
            --delete=${super_number} \
            --delete=${userdata_number} \
            --new=${super_number}:${SUPER_START}:${EXPANDED_SUPER_END} \
            --typecode=${super_number}:${super_type} \
            --partition-guid=${super_number}:${super_guid} \
            --change-name=${super_number}:super \
            --new=${userdata_number}:${EXPANDED_USERDATA_START}:${userdata_last} \
            --typecode=${userdata_number}:${userdata_type} \
            --partition-guid=${userdata_number}:${userdata_guid} \
            --change-name=${userdata_number}:userdata \
            "$DISK"
        sync
        verify_gpt
        read_layout
        [ "$layout" = expanded ] && [ "$userdata_last" = "$saved_userdata_last" ] || fail 'Unexpected GPT geometry after expansion; do not boot Android'
        echo "GPT update completed. A reboot is required before using super or userdata."
        ;;
    restore)
        [ "${FUXI_CONFIRM:-}" = RESTORE_STOCK_SUPER ] || \
            fail "Missing destructive-operation confirmation"
        check_saved_backup
        if [ "$layout" = stock ]; then
            echo "super is already stock 9 GiB; no GPT write is needed."
            exit 0
        fi
        unmount_partitions
        saved_userdata_last="$userdata_last"
        "$SGDISK" --set-alignment=1 \
            --delete=${super_number} \
            --delete=${userdata_number} \
            --new=${super_number}:${SUPER_START}:${STOCK_SUPER_END} \
            --typecode=${super_number}:${super_type} \
            --partition-guid=${super_number}:${super_guid} \
            --change-name=${super_number}:super \
            --new=${userdata_number}:${STOCK_USERDATA_START}:${userdata_last} \
            --typecode=${userdata_number}:${userdata_type} \
            --partition-guid=${userdata_number}:${userdata_guid} \
            --change-name=${userdata_number}:userdata \
            "$DISK"
        sync
        verify_gpt
        read_layout
        [ "$layout" = stock ] && [ "$userdata_last" = "$saved_userdata_last" ] || fail 'Unexpected GPT geometry after restore; do not boot Android'
        echo "GPT update completed. Super partition restored to stock 9 GiB. A reboot is required."
        ;;
    *)
        fail "Usage: $0 audit|apply|verify|restore"
        ;;
esac
