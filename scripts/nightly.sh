#!/usr/bin/env bash
# The nightly memory pipeline, run by launchd (com.108.memory-nightly) at 03:00.
#
# It replaces the Claude Desktop scheduled task "mine-memory-nightly". That task
# fell out of the Desktop scheduler's registry (its SKILL.md was still on disk,
# but the scheduler no longer listed it), so nothing ran after 2026-09-18 and the
# store went unchanged from 2026-09-05 (#23). launchd does not lose jobs that way,
# and a run missed while the machine slept fires on the next wake.
#
#   step 1  scripts/mine-nightly.sh   new facts from transcripts -> proposals/
#   step 2  scripts/verify-stale.sh   is the old memory still true -> proposals/*-stale.md
#   step 3  headless claude           accept what it can re-verify into the store, commit, push
#
# Steps 1 and 2 are scripts and run here. Step 3 needs judgement, so it is a
# `claude -p` run with the same prompt the Desktop task used (its SKILL.md, kept
# outside this public repo). The prompt is told that steps 1 and 2 already ran.
# Each step runs even if an earlier one failed: step 2 must run every night.
#
#   nightly.sh            run all three steps
#   nightly.sh --no-accept  run steps 1 and 2 only

set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/proposals"
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M)
LOG="$OUT/$STAMP-nightly.log"
PROMPT_FILE="${MEMQ_NIGHTLY_PROMPT:-$HOME/.claude/scheduled-tasks/mine-memory-nightly/SKILL.md}"
MODEL="${MEMQ_NIGHTLY_MODEL:-claude-opus-5-5}"

# One run at a time: a run that outlasts a wake-up catch-up must not overlap it.
LOCK="$DIR/.nightly.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date '+%F %T') another nightly run holds $LOCK; skipping" | tee -a "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

say "step 1: mine-nightly.sh"
"$DIR/scripts/mine-nightly.sh" >>"$LOG" 2>&1
RC1=$?
say "step 1 exit $RC1"

say "step 2: verify-stale.sh"
"$DIR/scripts/verify-stale.sh" >>"$LOG" 2>&1
RC2=$?
say "step 2 exit $RC2"

if [ "${1:-}" = "--no-accept" ]; then
  say "step 3 skipped (--no-accept)"
  exit $(( RC1 | RC2 ))
fi

if [ ! -r "$PROMPT_FILE" ]; then
  say "step 3: prompt file $PROMPT_FILE is missing; not accepting anything"
  exit 1
fi

say "step 3: accept into the store (claude -p, model $MODEL)"
PROMPT="Steps 1 and 2 of the pipeline below have ALREADY RUN in this round (step 1 exit $RC1, step 2 exit $RC2; their output is in $LOG and the newest files in $OUT). Do NOT run them again. Do only step 3, then write the report as the prompt describes.

$(cat "$PROMPT_FILE")"
claude -p "$PROMPT" --model "$MODEL" --max-turns 80 >>"$LOG" 2>&1
RC3=$?
say "step 3 exit $RC3"

exit $(( RC1 | RC2 | RC3 ))
