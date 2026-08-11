#!/usr/bin/env bash
# Every check in one command. Runs all three even if one fails — you want the
# whole picture, not the first thing that broke.
#
#   scripts/check-all.sh            # ~2 min: quality, freshness, 1000-query soak
#   scripts/check-all.sh --quick    # ~40 s: skips the soak
#   SOAK_N=10000 scripts/check-all.sh    # the full memory curve (~12 min)
#
#   bench-both.py      recall and dedup, both retrieval paths
#   freshness-test.py  a write / edit / delete is searchable at once
#   soak.py            memqd's RSS is not climbing
#
# A warm daemon soaks flat by definition — that is the useful daily signal
# ("still not growing"). To see the growth curve itself, restart memqd first:
#   launchctl kickstart -k gui/$UID/com.108.memqd
#
# Exit code is the number of checks that failed, so `&& deploy` behaves.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

SOAK_N="${SOAK_N:-1000}"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

CHECKS=("bench-both.py" "freshness-test.py")
[ "$QUICK" -eq 0 ] && CHECKS+=("soak.py $SOAK_N")

# Both of the first two need the daemon; say so once, clearly, instead of
# letting each script fail its own way.
if [ ! -S "$HOME/.cache/memory-search/memqd.sock" ]; then
    echo "memqd is not listening — nothing can be checked."
    echo "  launchctl kickstart -k gui/\$UID/com.108.memqd"
    exit 1
fi

failed=0
results=()
start=$SECONDS

for check in "${CHECKS[@]}"; do
    echo "══════════════════════════════════════════ $check"
    t0=$SECONDS
    # shellcheck disable=SC2086  # the soak's N is a deliberate second word
    "./scripts/"$check
    code=$?
    took=$((SECONDS - t0))
    if [ $code -eq 0 ]; then
        results+=("  PASS  ${check}  (${took}s)")
    else
        results+=("  FAIL  ${check}  (${took}s, exit $code)")
        failed=$((failed + 1))
    fi
    echo
done

echo "══════════════════════════════════════════ summary"
printf '%s\n' "${results[@]}"
echo "  $((SECONDS - start))s total"
[ "$QUICK" -eq 1 ] && echo "  (--quick: soak skipped)"

exit $failed
