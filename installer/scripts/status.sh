# Structured journal: only fixed actions/statuses; never raw output or serials.
EVENT_FILE=''
record_event() { [ -z "$EVENT_FILE" ] || printf '%s\t%s\n' "$1" "$2" >> "$EVENT_FILE"; }
mutation_action() {
    local tool="$1" previous='' item
    shift
    if [ "$tool" = adb ]; then
        case "$*" in *FUXI_CONFIRM=*) printf 'gpt.resize';; esac
        return
    fi
    for item in "$@"; do
        case "$previous:$item" in
            flash:super|flash:boot_a|flash:init_boot_a|flash:vendor_boot_a|flash:dtbo_a|flash:recovery_a|flash:vbmeta_a|flash:vbmeta_system_a) printf 'flash.%s' "$item"; return ;;
            erase:userdata|erase:metadata) printf 'erase.%s' "$item"; return ;;
            set_active:a) printf 'activate.a'; return ;;
        esac
        previous="$item"
    done
}
show_failure_state() {
    [ -n "$EVENT_FILE" ] && [ -f "$EVENT_FILE" ] || return 0
    record_event result failed
    get_text failureState >&2
    awk -F '\t' '$1 ~ /^phase\./ {last=$1} END {print "  " (last ? last : "startup")}' "$EVENT_FILE" >&2
    local last done
    last="$(awk -F '\t' '$1 ~ /^(flash\.|erase\.|activate\.|gpt\.)/ && $2=="started" {last=$1} END {print last}' "$EVENT_FILE")"
    done="$(awk -F '\t' '$1 ~ /^(flash\.|erase\.|activate\.|gpt\.)/ && $2=="done" {printf "%s%s", sep, $1; sep=", "}' "$EVENT_FILE")"
    if [ -n "$last" ]; then
        get_text partialWrites >&2
        get_text lastWrite "$last" >&2
        get_text doneWrites "$done" >&2
    else get_text noWrites >&2; fi
    get_text reportHelp >&2
}
readiness() { record_event "ready.$1" "$2"; printf '  %s: %s\n' "$(get_text "$1")" "$2"; }
show_local_readiness() {
    get_text quickScope
    local name missing=0 candidate free space=0
    for name in super.img.zst recovery.img vbmeta.img vbmeta_system.img "${EXTRA_IMAGES[@]/%/.img}"; do
        [ -f "$IMAGES/$name" ] || { printf 'Missing: %s\n' "$name"; missing=1; }
    done
    [ -f "$TOOLS/TWRP-FUXI-A17.img" ] || missing=1
    if [ "$missing" = 0 ]; then readiness bundlePresent OK; else readiness bundlePresent BLOCKED; fi
    readiness firmwareHashes UNKNOWN
    readiness compatibility UNKNOWN
    for candidate in "${TMPDIR:-/tmp}" "${HOME:-/tmp}/.cache" "$ROOT"; do
        [ -d "$candidate" ] && [ -w "$candidate" ] || continue
        free="$(df -Pk "$candidate" | awk 'END {print $4}')" || continue
        [[ "$free" =~ ^[0-9]+$ ]] || continue
        if [ "$((free * 1024))" -ge "$((SUPER_SPARSE_BYTES + 1073741824))" ]; then space=1; fi
    done
    if [ "$space" = 1 ]; then readiness diskSpace OK; else readiness diskSpace BLOCKED; fi
    get_text spaceProbe
}
show_fastboot_readiness() {
    local slot="${1#_}" unlocked="$2" userspace="$3" size="$4" clean=BLOCKED update=BLOCKED
    if [ "$unlocked" = yes ] && [ "$userspace" = no ]; then
        if { [ "$size" = "$EXPANDED_SUPER" ] && { [ "$slot" = a ] || [ "$slot" = b ]; }; } || { [ "$size" = "$STOCK_SUPER" ] && [ "$slot" = a ]; }; then clean=OK; fi
        if [ "$size" = "$EXPANDED_SUPER" ] && [ "$slot" = a ]; then update=OK; fi
    fi
    readiness cleanTechnical "$clean"
    readiness updateTechnical "$update"
}
