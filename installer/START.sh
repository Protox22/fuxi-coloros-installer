#!/usr/bin/env bash
# Linux entry point; no Python or GUI toolkit is needed.
exec bash "$(cd "$(dirname "$0")" && pwd)/scripts/menu.sh" "$@"
