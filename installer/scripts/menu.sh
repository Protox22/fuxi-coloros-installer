#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/language.sh"
if [ "$#" -gt 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --language ] || { printf 'Usage: bash START.sh [--language ru|en|pl]\n' >&2; exit 1; }
    LANGUAGE="$2"
fi
case "$LANGUAGE" in ru|en|pl) ;; *) printf 'Use ru, en or pl.\n' >&2; exit 1 ;; esac
last_result=0
while true; do
    printf '\n  FUXI / COLOROS                          v2.6.1\n'
    get_text welcome
    get_text intro
    printf '\n  [1] %s\n  [2] %s\n  [3] %s\n  [4] %s\n  [5] %s\n' \
        "$(get_text install)" "$(get_text restore)" "$(get_text verify)" "$(get_text diagnose)" "$(get_text help)"
    printf '  [6] %s\n' "$(get_text supportReport)"
    printf '  [L] %s: %s / RU / EN / PL\n  [0] %s\n' "$(get_text language)" "$LANGUAGE" "$(get_text exit)"
    get_text eraseWarning
    printf '%s: ' "$(get_text choice)"
    read -r selection || exit "$last_result"
    case "$selection" in
        0|'') exit "$last_result" ;;
        l|L) case "$LANGUAGE" in ru) LANGUAGE=en ;; en) LANGUAGE=pl ;; pl) LANGUAGE=ru ;; esac; continue ;;
        1)
            build=()
            if [ -f "$ROOT/../FUXI-KSU/BUILD_TYPE.txt" ] || [ -f "$ROOT/../FUXI-NO-ROOT/BUILD_TYPE.txt" ]; then
                printf '\n%s\n  [1] %s\n  [2] %s\n  [3] %s\n  [0] %s\n' "$(get_text buildTitle)" "$(get_text buildKsu)" "$(get_text buildNoRoot)" "$(get_text buildCurrent)" "$(get_text buildBack)"
                read -r choice || exit "$last_result"
                case "$choice" in 1) build=(--build ksu) ;; 2) build=(--build no-root) ;; 3) ;; 0|'') continue ;; *) get_text buildInvalid; continue ;; esac
            fi
            while true; do
                printf '\n%s\n  [1] %s\n  [2] %s\n  [0] %s\n' "$(get_text modeTitle)" "$(get_text modeClean)" "$(get_text modeUpdate)" "$(get_text buildBack)"
                read -r mode || exit "$last_result"
                case "$mode" in 1) mode=--clean; break ;; 2) mode=--update; break ;; 0|'') continue 2 ;; *) get_text modeInvalid ;; esac
            done
            command=(bash "$ROOT/flash.sh" "${build[@]}" "$mode") ;;
        2) command=(bash "$ROOT/restore-super.sh") ;;
        3)
            command=(bash "$ROOT/flash.sh" --verify-only)
            [ -f "$ROOT/images/super.img.zst" ] || command+=(--installer-only) ;;
        4) command=(bash "$ROOT/check-base.sh") ;;
        6) command=(bash "$ROOT/support-report.sh") ;;
        5) cat "$ROOT/QUICK_START.txt"; if [ -t 0 ]; then read -r -p "$(get_text returnMenu)" _ || exit "$last_result"; fi; continue ;;
        *) get_text invalid; continue ;;
    esac
    # A separate Bash preserves errexit inside the operation.
    export LANGUAGE COMPACT=1
    set +e
    "${command[@]}"
    last_result=$?
    set -e
    [ "$last_result" -ne 1 ] || get_text stopped
    if [ -t 0 ]; then read -r -p "$(get_text returnMenu)" _ || exit "$last_result"; fi
done
