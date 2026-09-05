#!/usr/bin/env bash
# Build both binaries and install them OUTSIDE target/ — the one thing that
# keeps this tool alive across a disk cleanup.
#
#   scripts/install.sh                    # build + install into ~/.local/bin
#   scripts/install.sh --prefix ~/bin     # somewhere else
#   scripts/install.sh --no-build         # install what is already built
#
# Why not just point everything at target/release/ (what this repo did until
# 2026-08-29): four separate things reference the binaries by absolute path —
# the MCP server entry in ~/.claude.json, the UserPromptSubmit hook in
# ~/.claude/settings.json, JetBrains Air's mcp.json, and the launchd plist. When `cargo clean` or a disk
# sweep removed target/, all four broke at once and the next session started
# with no memory at all and an ENOENT it could not fix by itself.
#
# The copy is a rename, not an overwrite: memqd is usually running from the file
# being replaced, and writing into a live binary fails with ETXTBSY (or, worse,
# corrupts the running image). Renaming over it gives the new file a new inode
# and leaves the running process on the old one until it is restarted below.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PREFIX="$HOME/.local/bin"
BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a directory}"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ "$BUILD" -eq 1 ]; then
    echo "==> cargo build --release"
    cargo build --release --bin memq --bin memory-search
fi

for bin in memq memory-search; do
    [ -f "target/release/$bin" ] || { echo "target/release/$bin is missing — run without --no-build" >&2; exit 1; }
done

mkdir -p "$PREFIX"
for bin in memq memory-search; do
    cp target/release/"$bin" "$PREFIX/.$bin.new"
    chmod 755 "$PREFIX/.$bin.new"
    mv -f "$PREFIX/.$bin.new" "$PREFIX/$bin"
    echo "==> installed $PREFIX/$bin"
done

# launchd expands neither ~ nor $HOME, so the plist carries absolute paths. The
# committed copy is written for this repo's author; substitute whoever is
# running it so the same file works on another machine.
PLIST="$HOME/Library/LaunchAgents/com.108.memqd.plist"
mkdir -p "$(dirname "$PLIST")"
sed -e "s#/Users/yongyutjantaboot#$HOME#g" \
    -e "s#<string>[^<]*/memq</string>#<string>$PREFIX/memq</string>#" \
    scripts/com.108.memqd.plist > "$PLIST"
echo "==> wrote $PLIST"

# KeepAlive only replaces a *dead* process; it does not notice a new binary.
# `bootout` returns before launchd has finished tearing the job down, and a
# `bootstrap` that lands in that window fails with "5: Input/output error" —
# which reads like a broken plist and is not. Wait for the job to actually go.
launchctl bootout gui/"$UID"/com.108.memqd 2>/dev/null || true
for _ in $(seq 1 25); do
    launchctl print gui/"$UID"/com.108.memqd >/dev/null 2>&1 || break
    sleep 0.2
done
launchctl bootstrap gui/"$UID" "$PLIST"
echo "==> memqd restarted on the new binary"

# The MCP server is a per-session child of the harness — kill it and the
# harness respawns it on the new binary within seconds, no app restart.
pkill -f "bin/memory-search" 2>/dev/null || true

# Anything still pointing into target/ will break the next time it is cleaned.
if ! scripts/check-stale-paths.sh "$PREFIX"; then
    STALE=1
else
    STALE=0
fi

echo
if [ "$STALE" -eq 0 ]; then
    echo "Done. Nothing references target/ any more, so it is safe to delete."
    echo "Check: tail ~/Library/Logs/memqd.log"
else
    echo "Done, but see the warnings above — those paths still break on a clean."
    exit 1
fi
