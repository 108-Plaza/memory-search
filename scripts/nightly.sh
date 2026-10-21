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
#   step 3  headless claude           re-verify proposals, stage accepted files -> proposals/*-accept/
#           this script               copy staged files into the store, commit them by path, push
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

say "step 3: re-verify and stage (claude -p, model $MODEL)"
STORE="${MEMQ_STORE:-$HOME/.claude/shared-memory/pos108}"
# Step 3 cannot write the store itself: ~/.claude is a protected path, and nothing short of a
# broad grant lets a headless run write there (2026-10-21: every store write was denied, and
# the run still exited 0). So step 3 writes full copies of what it accepts into STAGE, and
# this script, not the model, copies them into the store and commits exactly those paths.
STAGE="$OUT/$STAMP-accept"
mkdir -p "$STAGE"
T0=$(date +%s)
# Paths uncommitted before this run are not this job's to commit (#23 §6).
PENDING=$(git -C "$STORE" status --porcelain | cut -c4-)
PROMPT="Steps 1 and 2 of the pipeline below have ALREADY RUN in this round (step 1 exit $RC1, step 2 exit $RC2; their output is in $LOG and the newest files in $OUT). Do NOT run them again. Do only step 3, then write the report as the prompt describes.

You cannot write the store at $STORE and must not try, with any tool. Instead, for every store file you would add or change, write its COMPLETE new content to $STAGE/<its path relative to the store> (to change an existing file, read it from the store and write the whole edited copy). Write a one-line commit message to $STAGE/COMMIT_MSG. The calling script then scans those files, copies them into the store, commits exactly those paths and pushes, so skip the commit/push sub-step. Never stage a deletion.

These store paths were ALREADY uncommitted before this run and the owner has not approved them. Never stage them. If MEMORY.md is one of them, link new memories from a hub instead:
${PENDING:-(none)}

$(cat "$PROMPT_FILE")"
# Headless, so nothing can be approved: list exactly what step 3 may do, and load no user
# settings (their allow list includes merging PRs, which a run fed by transcripts must not inherit).
JSON=$(mktemp)
(cd "$DIR" && claude -p "$PROMPT" --model "$MODEL" --max-turns 80 --output-format json \
  --setting-sources project --permission-mode dontAsk \
  --allowedTools "Read,Glob,Grep,mcp__memory-search__memory_search,Edit(/$STAGE/**),Edit(/$OUT/*.md),Bash(rm -f $OUT/*),Bash(gh pr view:*),Bash(gh api repos/*)") >"$JSON" 2>>"$LOG"
RC3=$?
# Exit 0 is not proof (mine-nightly.sh records a refusal that exited 0): a denied call fails the run.
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("result","")); n=d.get("permission_denials") or []; [print("DENIED:", x["tool_name"], json.dumps(x["tool_input"])[:300]) for x in n]; sys.exit(2 if n else 0)' "$JSON" >>"$LOG" 2>&1 \
  || { say "step 3: a tool call was denied or its output was unreadable"; RC3=1; }
rm -f "$JSON"

say "step 3: apply $STAGE to the store"
APPLIED=()
while IFS= read -r f; do
  rel=${f#"$STAGE"/}
  [ "$rel" = COMMIT_MSG ] && continue
  case "$rel" in
    *..*|*[!A-Za-z0-9._/-]*|*[!d]|*[!m]d|*[!.]md) say "refused $rel: not a plain .md store path"; RC3=1; continue ;;
  esac
  if printf '%s\n' "$PENDING" | grep -qFx "$rel"; then
    say "refused $rel: it was pending before this run and is not approved"; RC3=1; continue
  fi
  cmp -s "$f" "$STORE/$rel" && continue
  if [ -e "$STORE/$rel" ] && [ "$(stat -f %m "$STORE/$rel")" -ge "$T0" ]; then
    say "refused $rel: someone changed it in the store during this run"; RC3=1; continue
  fi
  if grep -Eq 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|github_pat_|AKIA[0-9A-Z]{16}|xox[abpr]-|sk-ant-' "$f"; then
    say "refused $rel: it looks like it holds a secret"; RC3=1; continue
  fi
  mkdir -p "$(dirname "$STORE/$rel")" && cp "$f" "$STORE/$rel" && git -C "$STORE" add -- "$rel" \
    && APPLIED+=("$rel") || { say "could not apply $rel"; RC3=1; }
done < <(find "$STAGE" -type f | sort)

if [ ${#APPLIED[@]} -gt 0 ]; then
  MSG=$(head -1 "$STAGE/COMMIT_MSG" 2>/dev/null)
  # Commit only these paths: anything else already in the store's index is not this job's.
  git -C "$STORE" commit -q -m "${MSG:-store: nightly accept $STAMP}" -m "Applied by scripts/nightly.sh from proposals/$STAMP-accept." -- "${APPLIED[@]}" >>"$LOG" 2>&1 \
    || { say "commit failed"; RC3=1; }
fi
git -C "$STORE" fetch -q origin 2>>"$LOG"
AHEAD=$(git -C "$STORE" rev-list --count '@{u}..HEAD' 2>/dev/null || echo "?")
BEHIND=$(git -C "$STORE" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo "?")
if [ "$AHEAD" != 0 ] && [ "$BEHIND" = 0 ]; then
  git -C "$STORE" push -q origin HEAD 2>>"$LOG" && AHEAD=0 || say "push failed"
fi
[ "$AHEAD" != 0 ] && { say "store: $AHEAD commit(s) not pushed ($BEHIND behind origin: never merged here, a person decides)"; RC3=1; }
say "step 3 done: ${#APPLIED[@]} file(s) committed, exit $RC3; $(printf '%s' "$PENDING" | grep -c .) path(s) pending from before stay untouched"
[ "$RC3" -eq 0 ] && rm -rf "$STAGE"

exit $(( RC1 | RC2 | RC3 ))
