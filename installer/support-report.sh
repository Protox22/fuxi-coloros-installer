#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"
[ "$#" -eq 0 ] || fail 'Usage: bash support-report.sh (or menu option 6)'
command -v zip >/dev/null 2>&1 || fail 'ZIP export needs zip. Ubuntu/Debian: sudo apt install zip. Installation itself does not need zip.'
[ ! -L "$ROOT/logs" ] && [ ! -L "$ROOT/reports" ] || fail 'Linked logs/reports directories are not supported.'
source_file=''
for candidate in "$ROOT"/logs/*.events.tsv; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    [ "$(wc -c < "$candidate")" -le 8388608 ] || continue
    IFS= read -r first < "$candidate" || continue
    first="${first%$'\r'}"
    case "$first" in $'session.flash\tstarted'|$'session.restore\tstarted'|$'session.check-base\tstarted') ;; *) continue ;; esac
    if [ -z "$source_file" ] || [ "$candidate" -nt "$source_file" ]; then source_file="$candidate"; fi
done
[ -n "$source_file" ] || fail 'No structured session found. Run option 4, or an operation with installer 2.6, then retry.'
start_session export
mkdir -p "$ROOT/reports"
stage="$(mktemp -d "$ROOT/reports/.support.XXXXXXXX")"
# The EXIT handler owns only these exact files and the mktemp directory.
cleanup_report() {
    local code=$?
    trap - EXIT
    rm -f -- "$stage/events.tsv" "$stage/README.txt" "$stage/report.zip" || true
    rmdir -- "$stage" || true
    finish_session "$code"
}
trap cleanup_report EXIT
awk -F '\t' '
    { sub(/\r$/, "") }
    NF==2 && $1 ~ /^(session\.(flash|restore|check-base)|phase\.(verify|device|unpack)|flash\.(super|boot_a|init_boot_a|vendor_boot_a|dtbo_a|(recovery|vbmeta|vbmeta_system)_[ab])|erase\.(userdata|metadata)|activate\.a|gpt\.resize|result|error|ready\.(toolsAvailable|bundlePresent|firmwareHashes|compatibility|diskSpace|cleanTechnical|updateTechnical))$/ &&
    $2 ~ /^(started|done|finished|unfinished|failed|cancelled|OK|BLOCKED|UNKNOWN|hintFiles|hintLock|hintSpace|hintSlot|hintTools|hintUsb|hintStopped)$/ {print}
' "$source_file" > "$stage/events.tsv"
printf '%s\n' 'FUXI installer 2.6.1 - latest structured session' \
    'Only fixed operation/status codes are included. No serial, paths, raw logs, firmware or GPT backups.' \
    'UNKNOWN is not readiness approval. done means command success, not Android startup.' \
    'An interrupted started write may be partially applied. Do not resume midway.' > "$stage/README.txt"
destination="$ROOT/reports/FUXI-support-$(basename "$stage").zip"
[ ! -e "$destination" ] || fail 'Report destination already exists.'
(cd "$stage" && zip -q report.zip events.tsv README.txt) || fail 'ZIP export failed.'
mv -n -- "$stage/report.zip" "$destination"
[ ! -e "$stage/report.zip" ] || fail 'Report destination already exists.'
get_text reportCreated "$destination"
