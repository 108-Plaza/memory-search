#!/usr/bin/env bash
# ตรวจว่า memory เก่า "ยังจริงอยู่ไหม" — คู่ตรงข้ามของ mine-nightly.sh
#
# mine-nightly.sh หาของ *ใหม่* ที่ยังไม่มีใครเขียน สคริปต์นี้หาของ *เก่า* ที่เขียนไว้แล้ว
# แต่ความจริงเปลี่ยนไป ซึ่ง CLAUDE.md ระบุเองว่าเป็นความเสี่ยงอันดับหนึ่งของ workspace นี้:
# เอกสารที่ผิดอย่างมั่นใจได้ทั้งสองทิศ (2026-07-31 ไฟล์หนึ่งบอก "ยังไม่มีโค้ด" ทั้งที่ merge
# แล้ว อีกไฟล์บอก "พร้อม flip" ทั้งที่ส่ง field ที่ต้องใช้ไม่ได้)
#
# ใช้:  verify-stale.sh [N]     ตรวจ N ไฟล์ (default 12) หมุนตามวันที่ให้ครอบทั้ง store
#
# ⚠️ เจตนา: **ตรวจด้วยเครื่องล้วน ไม่มี LLM** ต่างจาก mine-nightly.sh โดยตั้งใจ —
# คำถามที่ถามคือ "PR นี้ merged จริงไหม / path นี้ยังอยู่ไหม" ซึ่งมีคำตอบที่ถูกต้องแน่นอน
# ให้โมเดลตอบเมื่อไหร่ก็เปิดช่องให้เดา รายงานนี้ต้องเชื่อได้ 100% ไม่งั้นไม่มีประโยชน์
#
# เขียนผลลง proposals/<stamp>-stale.md เหมือน miner — **ไม่แก้ memory store เอง**
# (กติกาเจ้าของ 2026-08-07: ห้ามอะไรก็ตามเขียน store อัตโนมัติ)

set -uo pipefail   # ไม่ใช้ -e: การเช็คที่ล้มเป็นเรื่องปกติ ต้องรายงานไม่ใช่ตาย
DIR="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$HOME/.claude/shared-memory/pos108"
WS="$HOME/108-POS"
OUT="$DIR/proposals"
N="${1:-12}"
mkdir -p "$OUT"

command -v gh >/dev/null || { echo "ต้องมี gh (auth แล้ว)" >&2; exit 1; }

# ชื่อโฟลเดอร์ใน ~/108-POS → repo บน GitHub
repo_of() {
  case "$1" in
    core)              echo "108-Plaza/pos108-core" ;;
    admin)             echo "108-Plaza/pos108-admin" ;;
    terminal)          echo "108-Plaza/pos108-terminal" ;;
    orders)            echo "108-Plaza/pos108-orders" ;;
    store)             echo "108-Plaza/pos108-store" ;;
    sell)              echo "108-Plaza/pos108-sell" ;;
    media)             echo "108-Plaza/Media-Platform" ;;
    platform-services) echo "108-Plaza/108-platform-services" ;;
    *)                 echo "" ;;
  esac
}

# หมุนชุดที่ตรวจตามวันของปี — 12 ไฟล์/คืน ครบ 256 ไฟล์ในราว 3 สัปดาห์
# (เรียงชื่อคงที่ + offset เลื่อนทุกวัน ⇒ ครอบคลุมทั่วถึงโดยไม่ต้องเก็บ state)
ALL=$(ls "$STORE"/*.md | grep -v '/MEMORY.md$' | grep -v -- '-history.md$' | sort)
TOTAL=$(echo "$ALL" | wc -l | tr -d ' ')
OFFSET=$(( ($(date +%j) * N) % TOTAL ))
FILES=$(echo "$ALL" | awk -v o="$OFFSET" -v n="$N" -v t="$TOTAL" \
  'NR>o && NR<=o+n {print} o+n>t && NR<=(o+n)-t {print}')

# รายชื่อไฟล์ที่ git ติดตามของทุกรีโปใน workspace รวบไว้ครั้งเดียว —
# เร็วกว่าและแม่นกว่าการไล่ `test -e` ทีละ base ที่เลือกมาเอง (รอบแรกพลาดเพราะแบบนั้น)
TRACKED=$(mktemp)
trap 'rm -f "$TRACKED"' EXIT
for d in "$WS"/*/; do
  [ -d "$d/.git" ] || continue
  ( cd "$d" && git ls-files 2>/dev/null | sed "s|^|$(basename "$d")/|" )
done > "$TRACKED"
REPOS=$(awk -F/ '{print $1}' "$TRACKED" | sort -u | wc -l | tr -d ' ')
[ ! -s "$TRACKED" ] && { echo "อ่านรายชื่อไฟล์จากรีโปไม่ได้เลย — ยกเลิก" >&2; exit 1; }

STAMP=$(date +%Y%m%d-%H%M)
REPORT="$OUT/$STAMP-stale.md"
FINDINGS=0
CHECKED_PR=0
CHECKED_PATH=0

{
  echo "# ตรวจความสดของ memory — $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "ตรวจ $N ไฟล์ (offset $OFFSET จาก $TOTAL) · เทียบกับ $REPOS รีโป · เครื่องตรวจล้วน ไม่มี LLM"
  echo
} > "$REPORT"

for f in $FILES; do
  name=$(basename "$f")
  body=""

  # ── 1. PR ที่อ้างถึง: หา repo keyword ภายใน 40 ตัวอักษรก่อนเลข # ──────────
  # รูปแบบจริงในสโตร์: "core PR #833", "admin #370", "terminal #157", "#834"
  # ตัวที่ไม่มี repo นำหน้า ข้ามไป (เดา repo ผิดแล้วรายงานผิดยิ่งแย่กว่าไม่รายงาน)
  while IFS='|' read -r slug num; do
    [ -z "$num" ] && continue
    repo=$(repo_of "$slug")
    [ -z "$repo" ] && continue
    CHECKED_PR=$((CHECKED_PR+1))
    state=$(gh pr view "$num" --repo "$repo" --json state,mergedAt --jq .state 2>/dev/null)
    [ -z "$state" ] && continue

    # หาบรรทัดที่อ้าง PR นี้ ไว้เทียบกับสิ่งที่ไฟล์อ้าง
    line=$(grep -m1 -- "#$num" "$f" | sed 's/^[[:space:]]*//' | cut -c1-160)
    claims_merged=$(echo "$line" | grep -ciE 'merged|merge|deployed|deploy|PROD|ขึ้นแล้ว|ครบแล้ว')
    claims_open=$(echo "$line" | grep -ciE 'OPEN|ค้าง|ยังไม่|รอ|pending|draft')

    if [ "$state" != "MERGED" ] && [ "$claims_merged" -gt 0 ] && [ "$claims_open" -eq 0 ]; then
      body="$body
- 🔴 **$repo#$num ยัง \`$state\`** แต่ไฟล์เขียนเหมือน merged แล้ว
  > \`$line\`"
      FINDINGS=$((FINDINGS+1))
    # claims_merged ต้องเป็น 0 ด้วย: บรรทัดที่เขียนว่า "Shipped (both merged)" แต่มีคำว่า
    # PENDING โผล่ในชื่อ enum (`PENDING/APPROVED`) เคยถูกนับเป็น "ยังค้าง" — คำที่เป็น
    # *ข้อมูล* ไม่ใช่ *คำกล่าวอ้าง* ต้องไม่ชนะคำกล่าวอ้างที่อยู่บรรทัดเดียวกัน
    elif [ "$state" = "MERGED" ] && [ "$claims_open" -gt 0 ] && [ "$claims_merged" -eq 0 ]; then
      body="$body
- 🟡 **$repo#$num \`MERGED\` แล้ว** แต่ไฟล์ยังเขียนว่าค้าง/รออยู่
  > \`$line\`"
      FINDINGS=$((FINDINGS+1))
    fi

    # เฉพาะ core: merged ≠ ถึงร้านจริง — prod เดินด้วย release/prod เท่านั้น
    # นี่คือคลาสที่กัดจริงเมื่อ 2026-08-09 (#833 merged แต่ยังไม่ถึง 8 ร้าน)
    if [ "$state" = "MERGED" ] && [ "$slug" = "core" ] && [ -d "$WS/core/.git" ]; then
      sha=$(gh pr view "$num" --repo "$repo" --json mergeCommit --jq .mergeCommit.oid 2>/dev/null)
      if [ -n "$sha" ] && git -C "$WS/core" cat-file -e "$sha^{commit}" 2>/dev/null; then
        if ! git -C "$WS/core" merge-base --is-ancestor "$sha" origin/release/prod 2>/dev/null; then
          body="$body
- ⚠️ **core#$num merged แต่ยังไม่อยู่บน \`origin/release/prod\`** — ร้านจริงยังไม่ได้ของนี้"
          FINDINGS=$((FINDINGS+1))
        fi
      fi
    fi
  done < <(grep -oiE '(core|admin|terminal|orders|store|sell|media|platform-services)[^#]{0,40}#[0-9]{2,4}' "$f" \
           | sed -E 's/^([A-Za-z-]+).*#([0-9]+)$/\1|\2/' | tr 'A-Z' 'a-z' | sort -u)

  # ── 2. path ที่อ้างถึงใน backtick — ยังมีอยู่จริงไหม ────────────────────────
  #
  # ⚠️ รอบแรกของสคริปต์นี้รายงาน 17 เรื่องจาก 6 ไฟล์ และ **ผิดทั้ง 17** เพราะไป
  # เช็คชื่อไฟล์เปล่า ๆ อย่าง `auth.rs`/`create_sale.rs` ที่ memory เอ่ยถึงเป็น "ชื่อ"
  # ไม่ใช่ "ที่อยู่" — ของพวกนั้นอยู่ลึกในทรี ไม่ได้อยู่ราก รายงานที่ false positive
  # ทั้งแผงแย่กว่าไม่มีรายงาน เพราะรอบสองไม่มีใครอ่านแล้ว จึงบังคับว่า:
  #   - ต้องมี `/` (เป็น path จริง ไม่ใช่ชื่อไฟล์ลอย)
  #   - ข้ามอันที่มี `...` (เขียนย่อไว้ ไม่ใช่ path ที่ resolve ได้)
  #   - เทียบกับ `git ls-files` ของทุก repo ไม่ใช่รายชื่อ base ที่เลือกมาเอง
  while read -r p; do
    [ -z "$p" ] && continue
    rel="${p%%:*}"
    case "$rel" in
      */*) ;;              # ผ่าน: เป็น path
      *)   continue ;;     # ชื่อไฟล์ลอย ๆ — ตัดสินไม่ได้ ข้าม
    esac
    case "$rel" in *...*|/*|~*) continue ;; esac

    # segment แรกต้องเป็นชื่อรีโปของเรา หรือ prefix ที่รีโปเราใช้จริง มิฉะนั้นข้าม —
    # memory อ้างถึงโค้ด *ข้างนอก* อยู่บ่อย ๆ (`MemoryProxy/...` ของ Tencent ที่เรา
    # ตั้งใจไม่รัน, `i-slint-backend-linuxkms-1.17.0/...` ที่เป็น crate ใน ~/.cargo)
    # ของพวกนั้น "ไม่มีในรีโปไหน" เป็นเรื่องถูกต้อง ไม่ใช่ความเพี้ยน
    case "${rel%%/*}" in
      src|crates|migrations|scripts|services|deploy|configuration|ui|tests|e2e|app|packages|docs|.github|.ai_context|frontend|clients)
        ;;
      *)
        grep -q "^${rel%%/*}/" "$TRACKED" || continue ;;
    esac
    CHECKED_PATH=$((CHECKED_PATH+1))

    if ! grep -qxF "$rel" "$TRACKED" && ! grep -qF "/$rel" "$TRACKED"; then
      # ไม่เจอที่อยู่นั้น — แยกให้ออกระหว่าง "ย้าย" กับ "หายไปเลย"
      if grep -qF "/${rel##*/}" "$TRACKED"; then
        body="$body
- 🟠 \`$rel\` ไม่อยู่ที่เดิมแล้ว แต่ยังมีไฟล์ชื่อนี้ที่อื่น — **น่าจะย้าย** ควรอัปเดต path"
      else
        body="$body
- 🔴 \`$rel\` **ไม่มีอยู่ในรีโปไหนแล้ว** (ลบ/เปลี่ยนชื่อ?)"
      fi
      FINDINGS=$((FINDINGS+1))
    fi
  done < <(grep -oE '`[a-zA-Z0-9_][a-zA-Z0-9_./-]*\.(rs|ts|tsx|sql|sh|py|toml|yaml|yml)(:[0-9]+)?`' "$f" \
           | tr -d '`' | sort -u | head -12)

  if [ -n "$body" ]; then
    { echo "## \`$name\`"; echo "$body"; echo; } >> "$REPORT"
  fi
done

{
  echo "---"
  echo
  echo "## สรุป"
  echo
  echo "| | |"
  echo "|---|--:|"
  echo "| ไฟล์ที่ตรวจ | $N |"
  echo "| PR ที่ยืนยันกับ GitHub | $CHECKED_PR |"
  echo "| path ที่เช็คการมีอยู่ | $CHECKED_PATH |"
  echo "| **เรื่องที่ต้องดู** | **$FINDINGS** |"
  echo
  if [ "$FINDINGS" -eq 0 ]; then
    echo "ไม่พบความเพี้ยนในรอบนี้ — ทุก PR และ path ที่ตรวจตรงกับความจริงปัจจุบัน"
  else
    echo "⚠️ ทั้งหมดนี้เป็น **ข้อเสนอ** ให้เจ้าของตัดสิน — สคริปต์ไม่แก้ store เอง"
  fi
} >> "$REPORT"

echo "เสร็จ → $REPORT  (พบ $FINDINGS เรื่อง จาก $N ไฟล์)"
