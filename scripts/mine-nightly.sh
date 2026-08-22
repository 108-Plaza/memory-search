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
STORE="$HOME/.claude/shared-memory/pos108"

# ── สำรองสโตร์ขึ้น GitHub (108-Plaza/pos108-memory, private) ──
#
# ⚠️ **push อย่างเดียว ห้าม `add`/`commit` เด็ดขาด** — กติกาเจ้าของ 2026-08-07:
# ไม่มีอะไรเขียนเข้าสโตร์เองได้ ข้อเสนออยู่ใน proposals/ เจ้าของรับเข้าเอง
# ตัวนี้จึงดันเฉพาะ commit ที่เจ้าของ commit ไว้แล้ว ไฟล์ที่ยังไม่ commit
# (เซสชันอื่นเขียนค้าง — ปกติมีเป็นสิบ) ไม่ถูกแตะและไม่ขึ้นไปไหน
#
# fast-forward เท่านั้น: ถ้า local ตาม origin อยู่ = มีคนดันจากเครื่องอื่น ให้ข้าม
# ไปเงียบ ๆ ให้คนมาดูเอง อย่าไปรวมสาขาเองตอนตีสาม
# push ล้มไม่ทำให้รอบขุดล้ม — มันเป็นงานสำรอง ไม่ใช่งานหลักของสคริปต์นี้
push_store() {
  git -C "$STORE" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$STORE" remote get-url origin >/dev/null 2>&1 || {
    echo "สโตร์: ไม่มี remote — ข้าม push"; return 0; }
  git -C "$STORE" fetch -q origin main 2>/dev/null || {
    echo "สโตร์: fetch ไม่ได้ — ข้าม push"; return 0; }
  local ahead behind
  ahead=$(git -C "$STORE" rev-list --count origin/main..main 2>/dev/null || echo 0)
  behind=$(git -C "$STORE" rev-list --count main..origin/main 2>/dev/null || echo 0)
  if [ "$behind" -ne 0 ]; then
    echo "สโตร์: ตาม origin อยู่ $behind commit (มีคนดันจากที่อื่น) — ไม่ push ให้คนมาดูเอง" >&2
    return 0
  fi
  if [ "$ahead" -eq 0 ]; then
    echo "สโตร์: ไม่มี commit ใหม่ให้ push"
    return 0
  fi
  if git -C "$STORE" push -q origin main 2>/dev/null; then
    echo "สโตร์: push $ahead commit ขึ้น origin แล้ว"
  else
    echo "สโตร์: push ล้ม (เน็ต/สิทธิ์?) — รอบขุดยังทำงานต่อ" >&2
  fi
}
# ── บอกทุกคืนว่ามี memory ค้างไม่ commit อยู่เท่าไร ──
#
# ทำไมต้องมี: push_store ดันเฉพาะของที่ commit แล้ว (กติกา 08-07) ⇒ ไฟล์ที่เซสชัน
# เขียนทิ้งไว้ **ไม่มีสำรองเลย** และมันเงียบมาก — 2026-08-12 เจอค้าง 39 ไฟล์
# ข้ามมา 4 วันโดยไม่มีใครรู้ตัว ตัวเลขบรรทัดเดียวทุกคืนทำให้ไม่ปล่อยยาวแบบนั้นอีก
# ตัวนี้ **อ่านอย่างเดียว** ไม่ commit ไม่แตะอะไรในสโตร์ — แค่บอกให้คนตัดสินใจ
report_uncommitted() {
  git -C "$STORE" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local n new mod oldest now days
  n=$(git -C "$STORE" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "สโตร์: ไม่มีไฟล์ค้าง — commit ครบแล้ว"
    return 0
  fi
  new=$(git -C "$STORE" status --porcelain | grep -c '^??' || true)
  mod=$(( n - new ))
  # เก่าสุด = mtime ที่น้อยที่สุดในกองที่ค้าง บอกว่า "ปล่อยไว้นานแค่ไหน"
  oldest=$(git -C "$STORE" status --porcelain | sed 's/^...//' | while IFS= read -r f; do
    [ -f "$STORE/$f" ] && stat -f %m "$STORE/$f"
  done | sort -n | head -1)
  now=$(date +%s)
  days=$(( (now - ${oldest:-$now}) / 86400 ))
  echo "⚠️ สโตร์: ค้างไม่ commit $n ไฟล์ (ใหม่ $new · แก้ $mod) เก่าสุด $days วัน — ยังไม่มีสำรอง"
}

# เรียกตรงนี้ ก่อนด่าน early-exit ทั้งหมด เพื่อให้สำรอง+รายงานทำงานทุกคืน
# แม้คืนนั้นจะไม่มี transcript ใหม่ให้ขุดเลย (ซึ่งเป็นกรณีที่พบบ่อยที่สุด)
if [ "${1:-}" != "--dry" ]; then
  push_store
  report_uncommitted
fi

# launch dirs ของ pos108 = ทุก dir ที่ขึ้นต้นด้วย -...-108-POS  +  home dir เปล่า ๆ
#
# ⚠️ เคยเป็นรายชื่อ hardcode 6 ตัว แล้ว "พลาดงานทั้งคืน" (2026-08-07): เซสชันที่รัน
# จาก ~/108-POS/terminal/pos-installer ไปอยู่ dir `-108-POS-terminal-pos-installer`
# ซึ่งไม่มีในรายชื่อ — เช่นเดียวกับ `-108-POS-memory-search` และ worktree ทุกตัว
# (`-108-POS-core--claude-worktrees-*` ฯลฯ) รวมแล้วมองไม่เห็นไป 15 ไฟล์
# แบบ prefix นี้ครอบ checkout/worktree ใหม่ที่จะเกิดขึ้นอีกโดยไม่ต้องมาแก้สคริปต์
#
# ⚠️ 2026-08-22: รีโป pos108 **ย้ายไป ~/IdeaProjects/108-Ting-Ecosystem/ แล้ว** และ
# ~/108-POS หายไป ⇒ งานส่วนใหญ่ไปอยู่ dir `-Users-...-IdeaProjects-108-Ting-Ecosystem*`
# (7 วันล่าสุด: 35 transcript ที่นั่น เทียบกับที่ -108-POS* เห็นได้น้อยกว่ามาก)
# จึงเพิ่ม prefix นั้นเข้ามา ไม่งั้น miner จะรายงาน "ไม่มี transcript ใหม่" ไปเรื่อย ๆ
# โดยไม่ error — เหตุผลเดิมที่กันไว้ ("คนละ memory store") เขียนตอน pos108 ยังอยู่ ~/108-POS
# ยังคงกัน -IdeaProjects* ตัวอื่น (108jobs-flutter ฯลฯ) ออกเหมือนเดิม
DIRS=()
while IFS= read -r d; do DIRS+=("$(basename "$d")"); done < <(
  find "$PROJ" -maxdepth 1 -type d \
    \( -name '-Users-yongyutjantaboot-108-POS*' \
       -o -name '-Users-yongyutjantaboot-IdeaProjects-108-Ting-Ecosystem*' \
       -o -name '-Users-yongyutjantaboot' \) \
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
CONVS=""
for f in $FILES; do
  i=$((i+1))
  python3 "$DIR/scripts/extract-conversation.py" "$f" > "$WORK/conv-$i.txt"
  CONVS="$CONVS
- $WORK/conv-$i.txt"
  echo "== transcript $i: $f ($(wc -l < "$WORK/conv-$i.txt" | tr -d ' ') turns)"
done

STAMP=$(date +%Y%m%d-%H%M)

# ⚠️ ต้องเป็น **ชื่อไฟล์จริงทีละบรรทัด** ห้ามกลับไปใช้ glob (`$WORK/conv-*.txt`)
# `Read` ขยาย glob ไม่ได้ และ --allowedTools ข้างล่างไม่มี Glob/LS/Bash ⇒ sub-agent
# ไล่ดูโฟลเดอร์เองไม่ได้เลย พอ Read ล้มมันจะ **เดาสาเหตุผิด** ว่าโดนบล็อกเพราะอยู่นอก
# cwd แล้วขอให้ย้ายไฟล์ แทนที่จะ error — บวกกับ `touch "$MARK"` ที่ไม่ดู exit code
# ข้างล่าง = watermark เดินทั้งที่ไม่ได้ขุด, transcript หายถาวร, เงียบสนิท (2026-08-12)
# ที่ผ่านมามันรอดเพราะบางคืนมันเดาชื่อ conv-1.txt ถูกเอง — สุ่มติดสุ่มหลุด ไม่ใช่เพิ่งพัง
PROMPT="คุณคือ memory miner ของ pos108. อ่านบทสนทนาต่อไปนี้ให้ครบทุกไฟล์ (ใช้ Read ทีละไฟล์ ด้วย path เต็มตามนี้):
$CONVS

สกัด fact ที่ควรจำถาวร: การตัดสินใจของเจ้าของ, root cause, gotcha, สิ่งที่ deploy/merge, กฎถาวร
ทุก fact ต้องเรียก tool memory_search ก่อน — score สูงเนื้อทับ = ทิ้ง, ทับบางส่วน = เสนอเป็น UPDATE ไฟล์เดิม, ไม่เจอ = NEW
ห้ามเก็บ secret/credential เป็น fact (เจอของหลุดให้ flag ⚠️ แยก)
เขียนผลด้วย Write ลงไฟล์ $OUT/$STAMP.md รูปแบบ: ## NEW (ต่อ fact: ชื่อไฟล์ kebab-case ที่เสนอ + เนื้อ 1-3 ประโยค self-contained + หลักฐาน) / ## UPDATES (ไฟล์เดิม + เพิ่มอะไร) / ## STATS (candidate/dup/new)
จบด้วยข้อความสั้น ๆ ว่าเขียนไฟล์แล้ว"

# โมเดล: ตั้งใจใช้ Sonnet ไม่ใช่ค่า default (= Opus ตามเซสชันที่เรียก) — งานนี้คือ
# extraction + ตัดสินว่าซ้ำไหม ซึ่ง Sonnet 5 ทำได้ใกล้ Opus ในสายนี้ และมันรัน **ทุกคืน**
# บน transcript ได้ถึง 5 ไฟล์ ไฟล์ละ 0.2–6 MB จึงเป็นจุดที่กินโทเคนซ้ำ ๆ มากที่สุด
#
# ⚠️ ห้ามลดไป Haiku โดยไม่วัด — ด่านที่ยากของ miner ไม่ใช่การ *อ่าน* แต่คือการ **ตัดสินว่า
# fact ไหนซ้ำของเดิม** (dedup rate 62–72% ในรอบที่ผ่านมา) ถ้าด่านนั้นอ่อนลง proposal จะ
# ท่วมด้วยของซ้ำ แล้วเจ้าของจะเลิกอ่าน — ซึ่งแพงกว่าค่าโทเคนที่ประหยัดได้มาก
# วัดก่อนเปลี่ยน: เทียบ STATS (dedup / NEW / UPDATES) กับรอบก่อนหน้า
MODEL="${MINER_MODEL:-sonnet}"

# ⚠️ ห้ามเช็ค `$?` เฉย ๆ หลัง pipe — `| tail -3` กลืน exit code ของ claude (ได้ของ tail แทน)
# และเพราะมี `set -e` + `pipefail` ถ้าปล่อยไว้ claude ล้มจะเด้งออกกลางคันก่อนถึงด่านตรวจ
# จึงปิด -e เฉพาะช่วงนี้แล้วอ่าน PIPESTATUS[0] (bash 3.2 รองรับ)
set +e
claude -p "$PROMPT" \
  --model "$MODEL" \
  --allowedTools "Read,Write,mcp__memory-search__memory_search" \
  --max-turns 40 2>&1 | tail -3
RC=${PIPESTATUS[0]}
set -e

# ⚠️ exit 0 ยัง **ไม่พอ** เป็นหลักฐานว่าขุดสำเร็จ — 2026-08-12 claude ออก 0 ทั้งที่ปฏิเสธงาน
# แล้วตอบเป็น prose โดยไม่เขียนไฟล์ผลเลย ground truth คือ "มีไฟล์ผลจริงและไม่ว่าง" ต่างหาก
# watermark ขยับต่อเมื่อผ่านทั้งสองด่าน — ล้มด่านไหนก็ไม่ขยับ รอบหน้าจะขุด transcript ชุดเดิมซ้ำ
# (ดีกว่าปล่อยผ่านเงียบ ๆ แล้ว transcript หายถาวร ซึ่งเป็นสิ่งที่ pipeline นี้มีไว้กันตั้งแต่แรก)
if [ "$RC" -ne 0 ]; then
  echo "miner ล้ม (exit $RC) — ไม่ขยับ watermark, รอบหน้าจะขุดชุดเดิมซ้ำ" >&2
  exit "$RC"
fi
if [ ! -s "$OUT/$STAMP.md" ]; then
  echo "miner ออก 0 แต่ไม่ได้เขียน $OUT/$STAMP.md — ไม่ขยับ watermark, รอบหน้าจะขุดชุดเดิมซ้ำ" >&2
  exit 1
fi

touch "$MARK"
echo "เสร็จ → $OUT/$STAMP.md  (รีวิวแล้วค่อยย้ายเข้ากองกลางเอง)"
