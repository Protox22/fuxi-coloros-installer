resolve_boot_variant() {
    local mode="$1" line key value count=0 prefix path expected
    local -A variant=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^([a-z0-9_]+)=([A-Za-z0-9_./-]+)$ ]] || fail 'Invalid boot-variants.conf.'
        key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
        case "$key" in format|ksu_image|ksu_sha256|no_root_image|no_root_sha256) ;; *) fail 'Unknown boot variant field.' ;; esac
        [ -z "${variant[$key]+present}" ] || fail 'Duplicate boot variant field.'
        variant[$key]="$value"; count=$((count+1))
    done < "$ROOT/boot-variants.conf"
    [ "$count" = 5 ] && [ "${variant[format]:-}" = 1 ] && [ "${variant[ksu_image]:-}" = images/boot.img ] && [ "${variant[no_root_image]:-}" = images/boot-no-root.img ] || fail 'Unsupported or incomplete boot variant configuration.'
    case "$mode" in ksu) prefix=ksu ;; no-root) prefix=no_root ;; *) fail 'Use root mode ksu or no-root.' ;; esac
    key="${prefix}_image"; path="$ROOT/${variant[$key]}";key="${prefix}_sha256";expected="${variant[$key]}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ -f "$path" ] && [ "$(hash_file "$path")" = "$expected" ] || fail 'Selected boot variant is missing or has the wrong SHA-256.'
    printf '%s\n' "$path"
}

extra_image_path() {
    if [ "$1" = boot ] && [ -n "$SELECTED_BOOT_IMAGE" ]; then printf '%s\n' "$SELECTED_BOOT_IMAGE"
    else printf '%s/%s.img\n' "$IMAGES" "$1"; fi
}
