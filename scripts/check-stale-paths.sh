#!/usr/bin/env bash
# Check known configuration files for stale references to target/release.
#
# Usage:
#   scripts/check-stale-paths.sh [PREFIX]

set -euo pipefail

PREFIX="${1:-$HOME/.local/bin}"

STALE_CANDIDATES=(
    "$HOME/.claude.json"
    "$HOME/.claude/settings.json"
    "$HOME/Library/Application Support/JetBrains/Air/mcp.json"
)

STALE=0
for f in "${STALE_CANDIDATES[@]}"; do
    if [ -f "$f" ]; then
        if [ ! -r "$f" ]; then
            echo "warning: $f is not readable, skipping stale check" >&2
            continue
        fi
        if grep -q "memory-search/target/release" "$f"; then
            echo "!!  $f still points into target/release — repoint it at $PREFIX" >&2
            STALE=1
        fi
    fi
done

exit "$STALE"
