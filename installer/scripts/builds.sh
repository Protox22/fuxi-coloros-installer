# Sourced by flash.sh only for an explicit --build ksu|no-root selection.
run_selected_build() {
    local root="$1" build="$2" folder marker expected actual name tool
    shift 2
    case "$build" in
        ksu) folder=FUXI-KSU ;;
        no-root) folder=FUXI-NO-ROOT ;;
        *) printf 'Use --build ksu or --build no-root.\n' >&2; return 1 ;;
    esac
    folder="$(dirname "$root")/$folder"
    marker="$folder/BUILD_TYPE.txt"
    if [ ! -f "$folder/flash.sh" ] || [ ! -f "$marker" ]; then
        printf 'Selected build has not been added: %s\n' "$build" >&2
        return 1
    fi
    actual="$(cat "$marker")"
    actual="${actual%$'\r'}"
    [ "$actual" = "$build" ] || { printf 'Build type does not match the selection.\n' >&2; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then tool=sha256sum
    elif command -v shasum >/dev/null 2>&1; then tool='shasum -a 256'
    else printf 'sha256sum or shasum is required.\n' >&2; return 1; fi
    expected="$(sed -n 's/^\([0-9a-fA-F]\{64\}\)  \.\/BUILD_TYPE\.txt\r\{0,1\}$/\1/p' "$folder/SHA256SUMS.txt")"
    actual="$($tool "$marker" | awk '{print $1}')"
    [ -n "$expected" ] && [ "${expected,,}" = "$actual" ] || { printf 'BUILD_TYPE.txt checksum is missing, duplicated or wrong.\n' >&2; return 1; }
    for name in scripts/status.ps1 scripts/status.sh support-report.ps1 support-report.sh START.sh scripts/menu.sh scripts/language.sh scripts/process.ps1 check-base.ps1 check-base.sh flash.ps1 flash.sh restore-super.ps1 restore-super.sh scripts/common.ps1 scripts/common.sh \
        scripts/language.ps1 scripts/menu.ps1 scripts/builds.ps1 scripts/builds.sh scripts/prepare-super.sh; do
        cmp -s "$root/$name" "$folder/$name" || { printf 'Selected build needs the current installer scripts: %s\n' "$name" >&2; return 1; }
    done
    bash "$folder/flash.sh" "$@"
}
