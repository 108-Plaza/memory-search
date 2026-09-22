#!/usr/bin/env bash
# Test harness for check-stale-paths.sh. Runs anywhere: no memqd, no cargo,
# no launchd — every case builds its own throwaway HOME and never touches the
# real one. Exit code is the number of cases that failed, like check-all.sh.
#
# Usage:
#   scripts/test-check-stale-paths.sh [script-to-test]
#
# The optional argument exists for the mutation proof in issue #19: point it
# at a copy to prove the Air cases really bite, without editing the original.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

TARGET="${1:-scripts/check-stale-paths.sh}"
STALE_NEEDLE='memory-search/target/release'

if [ ! -f "$TARGET" ]; then
    echo "$TARGET not found — merge PR #18 (issue #17) first" >&2
    exit 1
fi

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
FAKE_PREFIX="$TMPROOT/prefix"

# --- fixtures ---------------------------------------------------------------
# Each setup function receives the throwaway HOME and builds one scenario.

setup_empty_home() {
    :
}

setup_claude_json_stale() {
    printf '{"mcpServers":{"memory-search":{"command":"/opt/%s/memqd"}}}\n' \
        "$STALE_NEEDLE" >"$1/.claude.json"
}

setup_air_stale() {
    mkdir -p "$1/Library/Application Support/JetBrains/Air"
    printf '{"mcpServers":{"memory-search":{"command":"/opt/%s/memqd"}}}\n' \
        "$STALE_NEEDLE" >"$1/Library/Application Support/JetBrains/Air/mcp.json"
}

setup_air_clean() {
    mkdir -p "$1/Library/Application Support/JetBrains/Air"
    printf '{"mcpServers":{"memory-search":{"command":"%s/memory-search/memqd"}}}\n' \
        "$FAKE_PREFIX" >"$1/Library/Application Support/JetBrains/Air/mcp.json"
}

setup_air_absent() {
    # A clean .claude.json, and no Air file at all.
    printf '{"mcpServers":{"memory-search":{"command":"%s/memory-search/memqd"}}}\n' \
        "$FAKE_PREFIX" >"$1/.claude.json"
}

setup_both_stale() {
    setup_claude_json_stale "$1"
    setup_air_stale "$1"
}

# --- extra assertions (return 0 = pass) -------------------------------------
# Applied after the exit code already matched; they see the case's stderr in
# $CASE_STDERR_FILE and its HOME in $CASE_HOME.

assert_stderr_has_air_path() {
    grep -qF "$CASE_HOME/Library/Application Support/JetBrains/Air/mcp.json" "$CASE_STDERR_FILE"
}

assert_silent() {
    [ ! -s "$CASE_STDERR_FILE" ] && [ ! -s "$CASE_STDOUT_FILE" ]
}

assert_two_bang_lines() {
    [ "$(grep -c '^!!' "$CASE_STDERR_FILE")" -eq 2 ]
}

# --- runner -----------------------------------------------------------------

failed=0
total=0

run_case() {
    # run_case <name> <expected_exit> <setup_fn> [extra_assert_fn]
    local name="$1" expected="$2" setup="$3" extra="${4:-}"
    local home="$TMPROOT/home-$name"
    mkdir -p "$home"
    "$setup" "$home"

    CASE_HOME="$home"
    CASE_STDOUT_FILE="$TMPROOT/$name.stdout"
    CASE_STDERR_FILE="$TMPROOT/$name.stderr"
    HOME="$home" bash "$TARGET" "$FAKE_PREFIX" \
        >"$CASE_STDOUT_FILE" 2>"$CASE_STDERR_FILE"
    local code=$?
    total=$((total + 1))

    local why=""
    if [ "$code" -ne "$expected" ]; then
        why="expected exit $expected, got $code"
    elif [ -n "$extra" ] && ! "$extra"; then
        why="exit $code but the output assertion failed"
    fi

    if [ -z "$why" ]; then
        echo "PASS  $name"
    else
        echo "FAIL  $name ($why)"
        failed=$((failed + 1))
    fi
}

run_case empty-home        0 setup_empty_home
run_case claude-json-stale 1 setup_claude_json_stale
run_case air-stale         1 setup_air_stale       assert_stderr_has_air_path
run_case air-clean         0 setup_air_clean       assert_silent
run_case air-absent        0 setup_air_absent
run_case both-stale        1 setup_both_stale      assert_two_bang_lines

echo "$((total - failed))/$total passed"
exit $failed
