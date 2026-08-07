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

# launch dirs ของ pos108 (ตรงกับ symlink ในกองกลาง)
DIRS=(
  "-Users-yongyutjantaboot"
  "-Users-yongyutjantaboot-108-POS"
  "-Users-yongyutjantaboot-108-POS-admin"
  "-Users-yongyutjantaboot-108-POS-core"
  "-Users-yongyutjantaboot-108-POS-terminal"
  "-Users-yongyutjantaboot-108-POS-livechat"
)

# macOS bash 3.2 + set -u: การขยาย array ว่างนับเป็น unbound — ใช้ string แทน
NEWER=""
[ -f "$MARK" ] && NEWER="-newer $MARK"

# shellcheck disable=SC2086  # ตั้งใจไม่ quote $NEWER (ว่าง = ไม่มี filter)
# head ปิด pipe ก่อน find จบ → SIGPIPE + pipefail = exit 141; ครอบด้วย subshell+true
FILES=$( { for d in "${DIRS[@]}"; do
  find "$PROJ/$d" -maxdepth 1 -name '*.jsonl' $NEWER -mmin +30 \
    -size +200k -size -6M 2>/dev/null
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
