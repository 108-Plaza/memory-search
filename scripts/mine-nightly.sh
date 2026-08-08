#!/usr/bin/env bash
# ขุด fact จาก transcript ใหม่ (ตั้งแต่ watermark ล่าสุด) ด้วย headless Claude
# แล้ววางข้อเสนอไว้ที่ proposals/ ให้เจ้าของรีวิว — ไม่เขียน memory store เอง
#
# ใช้:  mine-nightly.sh          ขุดของใหม่ตั้งแต่รอบก่อน
#       mine-nightly.sh --dry    แค่ลิสต์ว่าจะขุดไฟล์ไหน
#
# ออกแบบ:
# - watermark = ไฟล์ timestamp; transcript ที่ mtime ใหม่กว่าถึงจะถูกขุด
# - เว้น session ที่ยังเขียนอยู่ (mtime < 30 นาที) กันขุดงานครึ่ง ๆ กลาง ๆ
# - จำกัดรอบละ 5 ไฟล์ ไฟล์ 0.2–6 MB — กันรอบแรกระเบิดใส่ 1.1 GB
# - ผลลง proposals/<date>.md — คนตัดสินใจ commit คือเจ้าของ ไม่ใช่ pipeline

set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$HOME/.claude/projects"
MARK="$DIR/.mine-watermark"
OUT="$DIR/proposals"
mkdir -p "$OUT"

# launch dirs ของ pos108 = ทุก dir ที่ขึ้นต้นด้วย -...-108-POS  +  home dir เปล่า ๆ
#
# ⚠️ เคยเป็นรายชื่อ hardcode 6 ตัว แล้ว "พลาดงานทั้งคืน" (2026-08-07): เซสชันที่รัน
# จาก ~/108-POS/terminal/pos-installer ไปอยู่ dir `-108-POS-terminal-pos-installer`
# ซึ่งไม่มีในรายชื่อ — เช่นเดียวกับ `-108-POS-memory-search` และ worktree ทุกตัว
# (`-108-POS-core--claude-worktrees-*` ฯลฯ) รวมแล้วมองไม่เห็นไป 15 ไฟล์
# แบบ prefix นี้ครอบ checkout/worktree ใหม่ที่จะเกิดขึ้นอีกโดยไม่ต้องมาแก้สคริปต์
#
# ที่ไม่รวมโดยตั้งใจ: -IdeaProjects* และ -108-Ting-Ecosystem* — คนละ memory store
# (ดู memory `memory-store-unified`) prefix ข้างล่างกันสองอันนี้ออกอยู่แล้ว
DIRS=()
while IFS= read -r d; do DIRS+=("$(basename "$d")"); done < <(
  find "$PROJ" -maxdepth 1 -type d \
    \( -name '-Users-yongyutjantaboot-108-POS*' -o -name '-Users-yongyutjantaboot' \) \
    2>/dev/null | sort
)
[ ${#DIRS[@]} -eq 0 ] && { echo "หา launch dir ไม่เจอเลย — ตรวจ \$PROJ" >&2; exit 1; }

# macOS bash 3.2 + set -u: การขยาย array ว่างนับเป็น unbound — ใช้ string แทน
NEWER=""
[ -f "$MARK" ] && NEWER="-newer $MARK"

# ⚠️ ขนาดต้องเป็นหน่วย BYTE (`c`) ทั้งคู่ ห้ามผสม k กับ M
# `find` บนเครื่องนี้คือ bfs 4.1.1 (ไม่ใช่ BSD find) และ `-size +200k -size -6M`
# คืน **ศูนย์ผลลัพธ์เงียบ ๆ** ทั้งที่แต่ละอันแยกกันถูกต้อง — อ่านออกมาเป็น
# "ไม่มี transcript ใหม่ให้ขุด" แทนที่จะเป็น error งานเลยเงียบไปทั้งคืน (2026-08-08)
MIN_BYTES=204800     # 200 KB
MAX_BYTES=6291456    # 6 MB

# ปกติเว้น session ที่ยังเขียนอยู่ (แก้ไขภายใน 30 นาที) — `--now` ข้ามด่านนี้
# สำหรับเทสต์ด้วยมือ ยอมขุด transcript ของ session ที่กำลังรันอยู่
FRESH="-mmin +30"
[ "${1:-}" = "--now" ] && FRESH=""

# shellcheck disable=SC2086  # ตั้งใจไม่ quote $NEWER/$FRESH (ว่าง = ไม่มี filter)
# head ปิด pipe ก่อน find จบ → SIGPIPE + pipefail = exit 141; ครอบด้วย subshell+true
FILES=$( { for d in "${DIRS[@]}"; do
  find "$PROJ/$d" -maxdepth 1 -name '*.jsonl' $NEWER $FRESH \
    -size +${MIN_BYTES}c -size -${MAX_BYTES}c 2>/dev/null
done; } | head -5 || true)

if [ -z "$FILES" ]; then
  echo "ไม่มี transcript ใหม่ให้ขุด"
  exit 0
fi

echo "จะขุด:"; echo "$FILES" | sed 's/^/  /'
if [ "${1:-}" = "--dry" ]; then exit 0; fi

# แปลงเป็นบทสนทนา
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
i=0
for f in $FILES; do
  i=$((i+1))
  python3 "$DIR/scripts/extract-conversation.py" "$f" > "$WORK/conv-$i.txt"
  echo "== transcript $i: $f ($(wc -l < "$WORK/conv-$i.txt" | tr -d ' ') turns)"
done

STAMP=$(date +%Y%m%d-%H%M)
PROMPT="คุณคือ memory miner ของ pos108. อ่านบทสนทนาใน $WORK/conv-*.txt (ใช้ Read ทีละไฟล์)
สกัด fact ที่ควรจำถาวร: การตัดสินใจของเจ้าของ, root cause, gotcha, สิ่งที่ deploy/merge, กฎถาวร
ทุก fact ต้องเรียก tool memory_search ก่อน — score สูงเนื้อทับ = ทิ้ง, ทับบางส่วน = เสนอเป็น UPDATE ไฟล์เดิม, ไม่เจอ = NEW
ห้ามเก็บ secret/credential เป็น fact (เจอของหลุดให้ flag ⚠️ แยก)
เขียนผลด้วย Write ลงไฟล์ $OUT/$STAMP.md รูปแบบ: ## NEW (ต่อ fact: ชื่อไฟล์ kebab-case ที่เสนอ + เนื้อ 1-3 ประโยค self-contained + หลักฐาน) / ## UPDATES (ไฟล์เดิม + เพิ่มอะไร) / ## STATS (candidate/dup/new)
จบด้วยข้อความสั้น ๆ ว่าเขียนไฟล์แล้ว"

claude -p "$PROMPT" \
  --allowedTools "Read,Write,mcp__memory-search__memory_search" \
  --max-turns 40 2>&1 | tail -3

touch "$MARK"
echo "เสร็จ → $OUT/$STAMP.md  (รีวิวแล้วค่อยย้ายเข้ากองกลางเอง)"
