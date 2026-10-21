#!/usr/bin/env bash
# The nightly memory pipeline, run by launchd (com.108.memory-nightly) at 03:00.
#
# It replaces the Claude Desktop scheduled task "mine-memory-nightly". Desktop
# keeps one task registry per signed-in account, and runs only the signed-in
# account's. The task lived in one account's registry, dropped out of it after
# its last run on 2026-08-30, and the app has since been signed into other
# accounts, so the store went unchanged from 2026-09-05 (#23). launchd belongs to
# the macOS user, not to an app sign-in, and fires a run missed asleep on wake.
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
  # A run killed with SIGKILL never runs its trap; its lock must not skip every later night.
  if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
    echo "$(date '+%F %T') another nightly run holds $LOCK; skipping" | tee -a "$LOG"
    exit 0
  fi
  echo "$(date '+%F %T') $LOCK was left by a dead run; taking it" | tee -a "$LOG"
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

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
STORE="$HOME/.claude/shared-memory/pos108"
# Paths uncommitted before this run are not this job's to commit (#23 §6).
PENDING=$(git -C "$STORE" status --porcelain)
HEAD0=$(git -C "$STORE" rev-parse HEAD)
PROMPT="Steps 1 and 2 of the pipeline below have ALREADY RUN in this round (step 1 exit $RC1, step 2 exit $RC2; their output is in $LOG and the newest files in $OUT). Do NOT run them again. Do only step 3, then write the report as the prompt describes.

These store paths were ALREADY uncommitted before this run and the owner has not approved them. Never edit, add, commit or delete them; stage files by explicit path only, never 'git add -A' or '.'. If MEMORY.md is one of them, link new memories from a hub instead:
${PENDING:-(none)}

$(cat "$PROMPT_FILE")"
# Headless, so nothing can be approved: list exactly what step 3 may do, and load no user
# settings (their allow list includes merging PRs, which a run fed by transcripts must not inherit).
(cd "$DIR" && claude -p "$PROMPT" --model "$MODEL" --max-turns 80 \
  --setting-sources project --permission-mode dontAsk \
  --allowedTools "Read,Glob,Grep,mcp__memory-search__memory_search,Edit(/$STORE/**),Edit(/$OUT/**),Bash(git -C $STORE:*),Bash(gh pr view:*),Bash(gh api repos/*),Bash(rm -f $OUT/*)") >>"$LOG" 2>&1
RC3=$?
say "step 3 exit $RC3; store: $(git -C "$STORE" rev-list --count "$HEAD0"..HEAD) new commit(s), $(git -C "$STORE" status --porcelain | grep -c .) uncommitted path(s) (was $(printf '%s' "$PENDING" | grep -c .))"
LEAKED=$(git -C "$STORE" diff --name-only "$HEAD0" HEAD | grep -Fx -f <(printf '%s\n' "$PENDING" | cut -c4- | grep .))
[ -n "$LEAKED" ] && { say "step 3 committed paths that were pending before it ran: $LEAKED"; RC3=1; }

exit $(( RC1 | RC2 | RC3 ))
