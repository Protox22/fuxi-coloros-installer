#!/system/bin/sh
# Xiaomi 13 (fuxi) super 9 GiB <-> 11 GiB.
# Devine Machinery. Sector maps match the published fuxi ColorOS installer
# geometries (32/33 and 31/32, 4096-byte sectors). Runs only inside recovery.
set -eu
export LC_ALL=C
umask 077

DISK=${FUXI_GPT_DISK:-/dev/block/sda}
BACKUP=${FUXI_GPT_BACKUP:-/tmp/fuxi-gpt-before.bin}
CURRENT=${FUXI_GPT_CURRENT:-/tmp/fuxi-gpt-current.bin}
MOUNTS=${FUXI_GPT_MOUNTS:-/proc/mounts}
RESTORE_FILE=${FUXI_GPT_RESTORE:-/tmp/fuxi-gpt-restore.bin}

EXPECTED_SECTOR_SIZE=4096
EXPECTED_SUPER_TYPE=89A12DE1-5E41-4CB3-8B4C-B1441EB5DA38
EXPECTED_USERDATA_TYPE=1B81E7E6-F50D-419B-A739-2AEEF8DA3335
MIN_DISK_BYTES=68719476736
GROWTH_SECTORS=524288
STOCK_SUPER_BYTES=9663676416
EXPANDED_SUPER_BYTES=11811160064

fail() {
    echo "ERROR: $*" >&2
    if [ -n "${gpt_table:-}" ]; then
        printf 'Observed GPT table (read-only):\n%s\n' "$gpt_table" >&2
    fi
    if [ "${allow_rollback:-}" = 1 ] && [ "${rolling_back:-}" != 1 ] && [ -s "${BACKUP:-}" ]; then
        rolling_back=1
        echo 'FUXI_RESULT=rollback' >&2
        echo 'ERROR: reloading the audited GPT backup. Do not boot Android.' >&2
        "$SGDISK" --load-backup="$BACKUP" "$DISK" || echo 'ERROR: rollback command failed. Do not boot Android.' >&2
        sync || true
    fi
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required recovery tool is missing: $1"
}

find_sgdisk() {
    if [ -n "${FUXI_GPT_SGDISK:-}" ]; then
        SGDISK=$FUXI_GPT_SGDISK
    elif [ -x /system/bin/sgdisk ]; then
        SGDISK=/system/bin/sgdisk
    elif [ -x /sbin/sgdisk ]; then
        SGDISK=/sbin/sgdisk
    else
        SGDISK=$(command -v sgdisk) || fail 'sgdisk is missing from this recovery'
    fi
    [ -x "$SGDISK" ] || fail "Required recovery tool is missing: $SGDISK"
}

upper() {
    printf '%s' "$1" | tr 'a-f' 'A-F'
}

first_word_after_colon() {
    sed -n "s/^$1:[[:space:]]*//p" | sed -n '1{s/[[:space:]].*$//;p;}'
}

name_from_info() {
    sed -n "s/^Partition name: '\(.*\)'/\1/p" | sed -n '1p'
}

assert_recovery() {
    [ "$(getprop ro.product.device)" = fuxi ] || fail 'Recovery device is not fuxi'
    [ "$(getprop sys.boot_completed)" = 1 ] && fail 'Android is running. GPT changes are refused.'
    boot_mode="$(getprop ro.boot.mode)"
    boot_mode2="$(getprop ro.bootmode)"
    recovery_ok=0
    if [ "$boot_mode" = recovery ] || [ "$boot_mode2" = recovery ]; then
        recovery_ok=1
    fi
    if [ -n "$(getprop ro.twrp.version)" ] || [ -n "$(getprop ro.twrp.version.skkk.code)" ] || [ -n "$(getprop ro.orangefox.version)" ]; then
        recovery_ok=1
    fi
    [ "$recovery_ok" = 1 ] || fail 'Recovery was not identified. Refusing to change GPT.'
}

try_umount() {
    point=$1
    n=0
    while [ "$n" -lt 5 ]; do
        if umount "$point"; then
            return 0
        fi
        n=$((n + 1))
        sleep "${FUXI_SLEEP:-1}"
    done
    umount -f "$point"
}

unmount_partitions() {
    sync
    for point in /data/media /sdcard /system_root /system_ext /vendor_dlkm /odm_dlkm /system /vendor /product /odm /metadata /cache /data; do
        if awk -v point="$point" '$2 == point {found=1} END {exit !found}' "$MOUNTS"; then
            try_umount "$point" || fail "Cannot unmount $point; GPT was not changed"
        fi
    done
    i=0
    while [ "$i" -lt 5 ]; do
        remaining=$(awk '$1 ~ /^\/dev\/block\// {print $2}' "$MOUNTS")
        [ -n "$remaining" ] || return 0
        printf '%s\n' "$remaining" | while IFS= read -r point; do
            [ -n "$point" ] || continue
            umount "$point" || true
        done
        i=$((i + 1))
        sleep "${FUXI_SLEEP:-1}"
    done
    remaining=$(awk '$1 ~ /^\/dev\/block\// {print $2}' "$MOUNTS")
    if [ -n "$remaining" ]; then
        printf '%s\n' "$remaining" | while IFS= read -r point; do
            [ -n "$point" ] || continue
            umount -f "$point" || true
        done
    fi
    remaining=$(awk '$1 ~ /^\/dev\/block\// {print $2}' "$MOUNTS")
    [ -z "$remaining" ] || fail "Block-backed mounts remain; unmount them before retrying: $remaining"
}

resolve_partition() {
    partition_name=$1
    expected_block=$2
    [ -b "$expected_block" ] || fail "Expected $partition_name block device is missing: $expected_block"
    expected_id=$(stat -L -c '%t:%T' "$expected_block") || fail "Cannot identify $expected_block"
    printf '%s\n' "$expected_id" | grep -Eq '^[0-9a-fA-F]+:[0-9a-fA-F]+$' || fail "Invalid block identity for $expected_block"

    if [ -n "${FUXI_GPT_BY_NAME:-}${FUXI_GPT_BOOT_NAME:-}" ]; then
        directories="${FUXI_GPT_BY_NAME:-} ${FUXI_GPT_BOOT_NAME:-}"
    else
        directories="/dev/block/by-name /dev/block/bootdevice/by-name"
    fi
    for directory in $directories; do
        [ -n "$directory" ] || continue
        alias_block="$directory/$partition_name"
        if [ -e "$alias_block" ] || [ -L "$alias_block" ]; then
            resolved_block=$(readlink -f "$alias_block" 2>/dev/null) || fail "Cannot resolve $alias_block"
            [ -b "$alias_block" ] || fail "$alias_block -> $resolved_block is not a usable block device"
            alias_id=$(stat -L -c '%t:%T' "$alias_block") || fail "Cannot identify $alias_block"
            [ "$alias_id" = "$expected_id" ] || fail "Unsupported $partition_name mapping: $alias_block -> $resolved_block (device $alias_id); expected $expected_block (device $expected_id)."
        fi
    done
    printf '%s\n' "$expected_block"
}

read_layout() {
    [ -b "$DISK" ] || fail "Expected block device is missing: $DISK"
    gpt_table=$("$SGDISK" --print "$DISK") || fail 'Cannot read the GPT table'
    super_count=$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF == "super" {c++} END {print c+0}')
    userdata_count=$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF == "userdata" {c++} END {print c+0}')
    [ "$super_count" = 1 ] && [ "$userdata_count" = 1 ] || fail "Unsupported or ambiguous GPT names: super=$super_count userdata=$userdata_count"
    super_number=$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF == "super" {print $1}')
    userdata_number=$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF == "userdata" {print $1}')
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
    awk -v start="$SUPER_START" -v stock="$STOCK_SUPER_END" -v expanded="$EXPANDED_SUPER_END" \
        -v stock_b="$STOCK_SUPER_BYTES" -v expanded_b="$EXPANDED_SUPER_BYTES" \
        -v growth="$GROWTH_SECTORS" -v ustart="$STOCK_USERDATA_START" -v uexpanded="$EXPANDED_USERDATA_START" '
        BEGIN {
            stock_n = stock - start + 1
            expanded_n = expanded - start + 1
            if (stock_n * 4096 != stock_b) exit 1
            if (expanded_n * 4096 != expanded_b) exit 1
            if (uexpanded - ustart != growth) exit 1
            if (expanded - stock != growth) exit 1
        }' || fail 'Internal geometry check failed'

    other_parts=$(printf '%s\n' "$gpt_table" | awk '$1 ~ /^[0-9]+$/ && $NF != "super" && $NF != "userdata" {print $1, $2, $3, $NF}')

    SUPER_BLOCK=$(resolve_partition super "${DISK}${super_number}") || exit 1
    USERDATA_BLOCK=$(resolve_partition userdata "${DISK}${userdata_number}") || exit 1

    if [ -n "${FUXI_GPT_SECTOR:-}" ]; then
        sector_size=$(cat "$FUXI_GPT_SECTOR")
    else
        sector_size=$(cat /sys/class/block/sda/queue/logical_block_size)
    fi
    disk_bytes=$(blockdev --getsize64 "$DISK")
    case "$disk_bytes" in ''|*[!0-9]*) fail 'Invalid disk size' ;; esac
    [ "$sector_size" = "$EXPECTED_SECTOR_SIZE" ] || fail "Unexpected logical sector size: $sector_size"
    awk -v bytes="$disk_bytes" -v minimum="$MIN_DISK_BYTES" \
        'BEGIN { exit !(bytes + 0 >= minimum + 0) }' || \
        fail "Storage size is too small: $disk_bytes bytes (minimum required: $MIN_DISK_BYTES bytes)."
    disk_sectors=$(awk -v bytes="$disk_bytes" -v sector="$EXPECTED_SECTOR_SIZE" '
        BEGIN {
            if (bytes + 0 > 9007199254740991 || bytes % sector != 0) exit 1
            printf "%.0f\n", bytes / sector
        }') || fail 'Disk size is not sector-aligned or exceeds the exact supported range'

    info_super=$(partition_info "$super_number")
    info_userdata=$(partition_info "$userdata_number")
    super_type=$(upper "$(printf '%s\n' "$info_super" | first_word_after_colon 'Partition GUID code')")
    super_guid=$(upper "$(printf '%s\n' "$info_super" | first_word_after_colon 'Partition unique GUID')")
    super_first=$(printf '%s\n' "$info_super" | first_word_after_colon 'First sector')
    super_last=$(printf '%s\n' "$info_super" | first_word_after_colon 'Last sector')
    super_attrs=$(printf '%s\n' "$info_super" | first_word_after_colon 'Attribute flags')
    super_name=$(printf '%s\n' "$info_super" | name_from_info)
    userdata_type=$(upper "$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Partition GUID code')")
    userdata_guid=$(upper "$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Partition unique GUID')")
    userdata_first=$(printf '%s\n' "$info_userdata" | first_word_after_colon 'First sector')
    userdata_last=$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Last sector')
    userdata_attrs=$(printf '%s\n' "$info_userdata" | first_word_after_colon 'Attribute flags')
    userdata_name=$(printf '%s\n' "$info_userdata" | name_from_info)

    for number in "$super_first" "$super_last" "$userdata_first" "$userdata_last"; do
        case "$number" in ''|*[!0-9]*) fail 'Invalid partition sector number' ;; esac
    done
    for guid in "$super_guid" "$userdata_guid" "$super_type" "$userdata_type"; do
        printf '%s\n' "$guid" | grep -Eq '^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$' || fail 'Invalid partition GUID'
    done
    [ "$super_name" = super ] || fail "Partition $super_number is not named super"
    [ "$userdata_name" = userdata ] || fail "Partition $userdata_number is not named userdata"
    printf '%s\n' "$other_parts" | awk -v start="$SUPER_START" -v end="$userdata_last" '
        NF == 0 { next }
        {
            if (($3 + 0) >= (start + 0) && ($2 + 0) <= (end + 0)) exit 3
        }' || fail 'Another partition overlaps super/userdata'
    [ "$super_type" = "$EXPECTED_SUPER_TYPE" ] || fail "Unexpected super type GUID: $super_type"
    [ "$userdata_type" = "$EXPECTED_USERDATA_TYPE" ] || fail "Unexpected userdata type GUID: $userdata_type"
    [ "$super_first" = "$SUPER_START" ] || fail "Unexpected super start sector: $super_first"
    [ "$super_attrs" = 0000000000000000 ] || fail "Unexpected super attributes: $super_attrs"
    [ "$userdata_attrs" = 0000000000000000 ] || fail "Unexpected userdata attributes: $userdata_attrs"
    awk -v last="$userdata_last" -v first="$EXPANDED_USERDATA_START" \
        'BEGIN { exit !(last + 0 > first + 0) }' || fail 'userdata is too small'
    awk -v last="$userdata_last" -v sectors="$disk_sectors" \
        'BEGIN { exit !(last + 0 < sectors - 1) }' || fail 'userdata exceeds disk bounds'

    if [ "$super_last" = "$STOCK_SUPER_END" ] && [ "$userdata_first" = "$STOCK_USERDATA_START" ]; then
        layout=stock
    elif [ "$super_last" = "$EXPANDED_SUPER_END" ] && [ "$userdata_first" = "$EXPANDED_USERDATA_START" ]; then
        layout=expanded
    else
        fail "Unsupported super/userdata boundary: super ends at $super_last, userdata starts at $userdata_first"
    fi
}

partition_info() {
    "$SGDISK" --info="$1" "$DISK"
}

write_backup() {
    rm -f "$BACKUP"
    "$SGDISK" --backup="$BACKUP" "$DISK"
    [ -s "$BACKUP" ] || fail 'GPT backup was not created'
    echo "GPT backup: $BACKUP"
    sha256sum "$BACKUP"
}

verify_gpt() {
    result=$("$SGDISK" --verify "$DISK") || fail 'GPT verification command failed'
    printf '%s\n' "$result"
    printf '%s\n' "$result" | grep -q '^No problems found\.' || fail 'GPT verification reported problems'
}

check_saved_backup() {
    [ -s "$BACKUP" ] || fail 'Run audit and save the GPT backup on the computer first'
    hash=${FUXI_BACKUP_SHA256:-}
    [ "${#hash}" -eq 64 ] || fail 'Missing verified computer backup checksum'
    printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{64}$' || fail 'Invalid backup checksum'
    [ "$(sha256sum "$BACKUP" | awk '{print $1}')" = "$hash" ] || fail 'The recovery GPT backup changed after audit'
    rm -f "$CURRENT"
    "$SGDISK" --backup="$CURRENT" "$DISK"
    [ -s "$CURRENT" ] || fail 'Could not create a fresh GPT comparison copy'
    cmp "$BACKUP" "$CURRENT" >/dev/null 2>&1 || fail 'GPT changed after audit; run audit and save a new backup'
}

print_summary() {
    echo 'Device: Xiaomi 13 fuxi'
    echo "Disk bytes: $disk_bytes"
    echo "Disk sectors: $disk_sectors"
    echo "Logical sector size: $sector_size"
    echo "Current layout: $layout"
    echo "FUXI_LAYOUT=$layout"
    echo "super GPT entry: $super_number; block: $SUPER_BLOCK"
    echo "userdata GPT entry: $userdata_number; block: $USERDATA_BLOCK"
    echo "super: $super_first-$super_last"
    echo "userdata: $userdata_first-$userdata_last"
}

rewrite_boundary() {
    new_super_end=$1
    new_userdata_start=$2
    expected_layout=$3
    saved_other=$other_parts
    saved_userdata_last=$userdata_last
    saved_super_guid=$super_guid
    saved_userdata_guid=$userdata_guid
    check_saved_backup
    unmount_partitions
    allow_rollback=1
    "$SGDISK" --set-alignment=1 \
        --delete="$super_number" \
        --delete="$userdata_number" \
        --new="${super_number}:${SUPER_START}:${new_super_end}" \
        --typecode="${super_number}:${super_type}" \
        --partition-guid="${super_number}:${super_guid}" \
        --change-name="${super_number}:super" \
        --new="${userdata_number}:${new_userdata_start}:${saved_userdata_last}" \
        --typecode="${userdata_number}:${userdata_type}" \
        --partition-guid="${userdata_number}:${userdata_guid}" \
        --change-name="${userdata_number}:userdata" \
        "$DISK" || fail 'sgdisk rejected the partition update. Do not boot Android.'
    sync
    blockdev --rereadpt "$DISK" || echo 'WARNING: kernel did not reread the partition table. Reboot to bootloader before using super.' >&2
    sync
    verify_gpt
    read_layout
    [ "$layout" = "$expected_layout" ] || fail 'GPT layout is not the requested geometry. Do not boot Android.'
    [ "$userdata_last" = "$saved_userdata_last" ] || fail 'userdata end sector changed'
    [ "$super_guid" = "$saved_super_guid" ] || fail 'super unique GUID changed'
    [ "$userdata_guid" = "$saved_userdata_guid" ] || fail 'userdata unique GUID changed'
    [ "$other_parts" = "$saved_other" ] || fail 'A partition other than super/userdata changed'
    [ "$super_first" = "$SUPER_START" ] || fail 'super start sector changed'
    [ "$super_last" = "$new_super_end" ] || fail 'super end sector was not applied'
    [ "$userdata_first" = "$new_userdata_start" ] || fail 'userdata start sector was not applied'
    allow_rollback=0
}

load_backup() {
    [ "${FUXI_CONFIRM:-}" = LOAD_GPT_BACKUP ] || fail 'Missing destructive-operation confirmation'
    hash=${FUXI_BACKUP_SHA256:-}
    [ "${#hash}" -eq 64 ] || fail 'Missing verified computer backup checksum'
    printf '%s\n' "$hash" | grep -Eq '^[0-9a-f]{64}$' || fail 'Invalid backup checksum'
    [ -s "$RESTORE_FILE" ] || fail 'Restore image is missing'
    [ "$(sha256sum "$RESTORE_FILE" | awk '{print $1}')" = "$hash" ] || fail 'Restore image checksum mismatch'
    unmount_partitions
    "$SGDISK" --load-backup="$RESTORE_FILE" "$DISK" || fail 'sgdisk could not load the GPT backup. Do not boot Android.'
    sync
    verify_gpt
    read_layout
    print_summary
    echo 'FUXI_RESULT=backup-loaded'
}

mode=${1:-audit}
case "$mode" in
    audit|apply|verify|restore|load-backup) ;;
    *) fail "Usage: $0 audit|apply|verify|restore|load-backup" ;;
esac

for tool in blockdev sha256sum cmp readlink stat awk sed grep umount sync getprop cat tr sleep; do
    need_cmd "$tool"
done
assert_recovery
find_sgdisk

if [ "$mode" = load-backup ]; then
    load_backup
    exit 0
fi

read_layout
verify_gpt
print_summary

case "$mode" in
    audit)
        write_backup
        echo 'FUXI_RESULT=audit'
        ;;
    verify)
        [ "$layout" = expanded ] || fail 'super is not expanded'
        [ "$(blockdev --getsize64 "$SUPER_BLOCK")" = "$EXPANDED_SUPER_BYTES" ] || fail 'The live super block device is not 11 GiB'
        echo 'Expanded super layout verified.'
        echo 'FUXI_RESULT=verified'
        ;;
    apply)
        [ "${FUXI_CONFIRM:-}" = ERASE_AND_RESIZE ] || fail 'Missing destructive-operation confirmation'
        if [ "$layout" = expanded ]; then
            echo 'super is already 11 GiB; no GPT write is needed.'
            echo 'FUXI_RESULT=unchanged'
            exit 0
        fi
        rewrite_boundary "$EXPANDED_SUPER_END" "$EXPANDED_USERDATA_START" expanded
        echo 'GPT update completed. A reboot is required before using super or userdata.'
        echo 'FUXI_RESULT=applied'
        ;;
    restore)
        [ "${FUXI_CONFIRM:-}" = RESTORE_STOCK_SUPER ] || fail 'Missing destructive-operation confirmation'
        if [ "$layout" = stock ]; then
            echo 'super is already stock 9 GiB; no GPT write is needed.'
            echo 'FUXI_RESULT=unchanged'
            exit 0
        fi
        rewrite_boundary "$STOCK_SUPER_END" "$STOCK_USERDATA_START" stock
        echo 'GPT update completed. Super partition restored to stock 9 GiB. A reboot is required.'
        echo 'FUXI_RESULT=restored'
        ;;
    *)
        fail "Usage: $0 audit|apply|verify|restore|load-backup"
        ;;
esac
