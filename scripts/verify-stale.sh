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
# ⚠️ ต้องรวม ~/IdeaProjects ด้วย ไม่ใช่แค่ ~/108-POS — สโตร์นี้จำเรื่อง api-108jobs /
# 108jobs-flutter / Payment-Platform ซึ่ง **ไม่ได้อยู่ใน workspace นี้** และ path ของมัน
# ขึ้นต้นด้วย `crates/` เหมือนรีโปเรา จึงหลุดด่าน prefix ไปโดนตัดสินว่า "ไม่มีในรีโปไหน"
# (false positive จริงตอนกวาดทั้งสโตร์ 2026-08-09: crates/api/api_utils/src/{provision,utils}.rs
#  มีอยู่ครบใน ~/IdeaProjects/api-108jobs)
for d in "$WS"/*/ "$HOME"/IdeaProjects/*/; do
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

    # ทุกบรรทัดที่อ้าง PR นี้ ไม่ใช่แค่บรรทัดแรก — บรรทัดแรกมักเป็นการเกริ่น
    # ส่วนบรรทัดที่ *อ้างสถานะ* อยู่ถัดลงไป (จับผิดเป็น #412 ตอนกวาดทั้งสโตร์)
    lines=$(grep -- "#$num" "$f" | sed 's/^[[:space:]]*//')
    claims_merged=$(echo "$lines" | grep -ciE 'merged|merge|deployed|deploy|PROD|ขึ้นแล้ว|ครบแล้ว')
    # ⚠️ `OPEN` ต้องเป็นตัวใหญ่ทั้งคำ — สโตร์นี้เขียนสถานะเป็น "PR #335 to main OPEN"
    # ส่วนตัวเล็กเกือบทุกครั้งเป็น *คำธรรมดา*: "open-drawer" (ชื่อฟีเจอร์),
    # "forced open change form", "opened 2026-07-08" (เล่าว่าเปิด PR เมื่อไหร่)
    # ทั้งสามแบบเคยถูกนับเป็น "ยังค้าง" ตอนกวาดทั้งสโตร์ 2026-08-09
    # ฝั่งไทยก็ต้องเป็นวลี ไม่ใช่ `รอ` เดี่ยว ๆ (ไปโดน "รอบ", "รอง")
    claims_open=$(echo "$lines" | grep -cE '\bOPEN\b|\bPENDING\b|\bDRAFT\b|ยังไม่|ยังค้าง|รออยู่|ค้างอยู่')
    # บรรทัดที่ยกมาโชว์ = บรรทัดที่อ้างสถานะจริง ถ้าไม่มีค่อยใช้บรรทัดแรก
    line=$(echo "$lines" | grep -m1 -E '\bOPEN\b|\bPENDING\b|\bDRAFT\b|ยังไม่|ยังค้าง|รออยู่|ค้างอยู่|merged|MERGED|deployed')
    [ -z "$line" ] && line=$(echo "$lines" | head -1)
    line=$(echo "$line" | cut -c1-160)

    # เล่าอดีตไม่ใช่การอ้างสถานะปัจจุบัน — "the fix **was open** as core PR #833" คือการ
    # เล่าว่าตอนนั้นมันยังไม่ merge ไม่ได้แปลว่าไฟล์เข้าใจผิดว่าตอนนี้ยังค้าง
    # (false positive จริงจากรอบ 2026-08-09 03:10)
    echo "$line" | grep -qiE 'was |were |had been|used to|opened |at the time|เคย|ตอนนั้น|ก่อนหน้า' \
      && claims_open=0

    # ถ้าไฟล์เอ่ยสถานะจริงของ PR ไว้แล้ว = มันตรงกับ GitHub อยู่ ห้ามแจ้ง
    # เคสจริง: "PR #15 **was closed** and its content **rebased + merged as #25**"
    # คำว่า merged ในนั้นหมายถึง #25 ไม่ใช่ #15 — ไฟล์ถูกทุกอย่าง แต่โดนแจ้งว่าผิด
    # (false positive จากการที่เราขยายไปอ่านทุกบรรทัดที่เอ่ยเลขนั้น)
    agrees=$(echo "$lines" | grep -ci -- "$state")

    if [ "$agrees" -gt 0 ]; then
      :
    elif [ "$state" != "MERGED" ] && [ "$claims_merged" -gt 0 ] && [ "$claims_open" -eq 0 ]; then
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
  # `.*` แบบ greedy = เอา keyword **ตัวที่ใกล้ที่สุด** ก่อนเลข ไม่ใช่ตัวแรก
  # บรรทัด "core sha-598e25c; PRs admin #333 + core #572" เคยถูกอ่านเป็น core#333
  # (คนละ PR กันคนละเรื่อง) เพราะ sed เดิมหยิบ keyword ตัวแรกของ match
  done < <(grep -oiE '(core|admin|terminal|orders|store|sell|media|platform-services)[^#]{0,40}#[0-9]{2,4}' "$f" \
           | sed -E 's/.*(core|admin|terminal|orders|store|sell|media|platform-services)([^#]{0,40})#([0-9]+)$/\1|\3/I' \
           | tr 'A-Z' 'a-z' | sort -u)

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

# ── 3-5. ความสอดคล้องของ "บรรทัดสรุป" กับตัวไฟล์ ────────────────────────────
#
# คลาสนี้เพิ่มเมื่อ 2026-08-09 หลังพลาดสองครั้งในงานเดียว ตอนย่อ 118 memory ลงเป็น hub:
# ทั้งสองครั้งคือ **หยิบพาดหัวเดิมมาโดยไม่อ่านต่อ** — `pos108-kitchen-print-realtime`
# ถูกยกเป็น "ร้านบนคลาวด์ไม่พิมพ์ = 🔴" ทั้งที่ในไฟล์มี ⛔ ของเจ้าของบอกว่าเป็นดีไซน์ที่ถูก
# และ `pos108-core-ci-skips-all-crates-tests` ถูกยกเป็น "CI เชื่อไม่ได้" ทั้งที่ไฟล์เขียน
# **FIXED** ไว้ตั้งแต่ PR #830 · เซสชันใหม่อ่านบรรทัดสรุปแล้วสรุปผิดตามทันที
#
# บรรทัดสรุปมีสองที่ และทั้งสองที่คือ *สิ่งที่ถูกอ่านก่อน* เนื้อไฟล์เสมอ:
#   - `description:` ใน frontmatter — คือข้อความที่ `memory_search` คืนกลับมา
#   - บรรทัดใน `*-hub.md` — คือสิ่งที่เซสชันเห็นก่อนตัดสินใจว่าจะเปิดไฟล์ไหม
# ทั้งคู่ถูกเขียนตอนหนึ่ง แล้วไม่มีใครกลับมาแก้เมื่อเนื้อไฟล์เปลี่ยน
#
# ยังเป็นการตรวจด้วยเครื่องล้วน: ถามแค่ "ไฟล์ประกาศว่าจบแล้วหรือห้ามรายงานซ้ำไหม
# และบรรทัดสรุปพูดตรงกันไหม" ไม่ได้ให้ใครตีความว่าเนื้อหาถูกหรือผิด
python3 - "$STORE" "$REPORT" <<'PY' >> /dev/null
import re, sys, glob, os
store, report = sys.argv[1], sys.argv[2]

# เครื่องหมาย "เรื่องนี้จบแล้ว"
# LIVE/MERGED อยู่ในลิสต์ด้วย เพราะบรรทัดสรุปที่นี่มักเขียนว่า "✅ LIVE 2026-07-27" หรือ
# "merged + ขึ้น staging แล้ว" ซึ่ง *บอกแล้ว* ว่าจบ — ถ้าไม่นับ จะไล่แจ้งซ้ำของที่เพิ่งแก้ไป
# ⚠️ ฝั่งอังกฤษต้องมี \b ครอบ — ไม่งั้น `LIVE` ไปแมตช์กลางคำว่า "LIVES" ("WHERE IT LIVES
# NOW") แล้วรายงานว่าไฟล์ประกาศจบแล้ว ทั้งที่มันกำลังบอกว่าย้ายบ้าน · ฝั่งไทยใช้ \b ไม่ได้
# (ไม่มีช่องว่างคั่นคำ) จึงแยกเป็นสองก้อน · `MERGE` แยกจาก `MERGED` เพราะบรรทัดไทยเขียน
# ว่า "merge แล้ว"
DONE = (r'(?:\b(?:FIXED|RESOLVED|SUPERSEDED|SHIPPED|DEPLOYED|MERGED|MERGE|LIVE|CLOSED|DONE)\b'
        r'|(?:แก้แล้ว|ขึ้นแล้ว|ขึ้น staging|ขึ้น prod|เสร็จแล้ว|ยกเลิกแล้ว|ไม่ใช่บั๊ก))')

# ⚠️ ห้ามกวาดหา DONE ทั้งไฟล์ — ลองแล้วเมื่อ 2026-08-09 ได้ **90 finding จาก 6 ไฟล์
# และเกือบทั้งหมดผิด**: memory ที่นี่ยาวและเล่าสถานะรายข้อ ("Slice 2 DONE",
# "#4 DONE — PR #314 MERGED", "be **CLOSED**") ซึ่งเป็นสถานะของ *รายการย่อย*
# ไม่ใช่ของทั้งไฟล์ · รายงานที่ผิดทั้งแผงแย่กว่าไม่มีรายงาน เพราะรอบสองไม่มีใครอ่าน
# (บทเรียนเดียวกับตอน path check ผิด 17/17)
#
# สิ่งที่ตัดสินได้จริงคือ **บรรทัดแรกของเนื้อไฟล์** — ธรรมเนียมของสโตร์นี้คือขึ้นต้น
# ด้วยสถานะของทั้งไฟล์เมื่อมันเปลี่ยน ("## ✅ FIXED", "⚠️ SUPERSEDED …")
# ถ้าจะจับ "ทั้งไฟล์จบแล้วแต่ description ยังเล่าของเก่า" นี่คือสัญญาณเดียวที่ไม่เดา
LEAD = re.compile(r'^\s*(?:#{1,4}\s+)?(?:[⚠️✅⛔🔴🟡🟠]\s*)*\*{0,2}\s*[^\n]{0,25}' + DONE)

def lead_claim(body):
    """สถานะที่ประกาศไว้ 'หัวไฟล์' — 3 บรรทัดแรกที่ไม่ว่างเท่านั้น"""
    for ln in [l for l in body.splitlines() if l.strip()][:3]:
        if LEAD.match(ln):
            return ln.strip()
    return None

def parts(p):
    t = open(p, encoding='utf-8').read()
    m = re.match(r'^---\n(.*?)\n---\n(.*)$', t, re.S)
    return (m.group(1), m.group(2)) if m else ('', t)

def desc(front):
    m = re.search(r'(?m)^description:\s*(.*)$', front)
    return m.group(1).strip() if m else ''

out, n = [], 0
files = [f for f in sorted(glob.glob(os.path.join(store, '*.md')))
         if not f.endswith(('MEMORY.md',)) and not f.endswith('-history.md')]

# ── 3. description ตามเนื้อไฟล์ไม่ทัน ──────────────────────────────────────
# hub ไม่เข้าเกณฑ์นี้: description ของมันบรรยาย *ดัชนี* ไม่ใช่คำกล่าวอ้างเรื่องใดเรื่องหนึ่ง
for f in files:
    if f.endswith('-hub.md'):
        continue
    front, body = parts(f)
    d = desc(front)
    if not d:
        out.append(f"- 🟠 `{os.path.basename(f)}` — **ไม่มี `description:`** "
                   f"⇒ `memory_search` ไม่มีอะไรสรุปให้คนอ่านก่อนเปิดไฟล์")
        n += 1
        continue
    lead = lead_claim(body)
    if lead and not re.search(DONE, d, re.I):
        out.append(f"- 🟡 `{os.path.basename(f)}` — หัวไฟล์ประกาศว่าจบแล้ว แต่ `description:` "
                   f"ไม่ได้บอก — **เทียบเอง** (นี่คือข้อความที่ `memory_search` คืนกลับมา)\n"
                   f"  > ไฟล์: `{lead[:110]}`\n  > desc: `{d[:110]}`")
        n += 1


# ── 4. บรรทัดใน hub ขัดกับไฟล์ปลายทาง ──────────────────────────────────────
hubs = sorted(glob.glob(os.path.join(store, '*-hub.md')))
for h in hubs:
    text = open(h, encoding='utf-8').read()
    # ตัดเป็นก้อน bullet: เริ่มที่ "- " ไปจนถึง "- " ถัดไปหรือหัวข้อใหม่
    blocks = re.split(r'(?m)^(?=- |#{1,4} )', text)
    for b in blocks:
        if not b.startswith('- '):
            continue
        for target in set(re.findall(r'\[\[([A-Za-z0-9._-]+)\]\]', b)):
            tp = os.path.join(store, target + '.md')
            # ลิงก์ hub→hub ไม่เข้าเกณฑ์: ⛔/สถานะที่อยู่ใน hub อีกตัวเป็นของ *บรรทัดในนั้น*
            # ไม่ใช่ของบรรทัดที่ชี้มา (false positive จริงจากรอบแรก 2026-08-09)
            if not os.path.exists(tp) or target.endswith('-hub'):
                continue
            _, tbody = parts(tp)
            # 4a ไฟล์ปลายทางมี ⛔ (สิ่งที่เจ้าของสั่งว่าอย่ารายงานซ้ำ) แต่บรรทัด hub ไม่บอก
            stop = re.search(r'(?m)^.{0,10}⛔[^\n]*', tbody)
            if stop and '⛔' not in b:
                out.append(f"- 🟠 `{os.path.basename(h)}` → `[[{target}]]` — ไฟล์ปลายทางมี ⛔ "
                           f"แต่บรรทัด hub ไม่ได้บอก\n  > `{stop.group(0).strip()[:130]}`")
                n += 1
            # 4b ไฟล์ปลายทางประกาศว่าจบแล้ว แต่ bullet ยังเขียนเหมือนยังพังอยู่
            else:
                # 4b หัวไฟล์ปลายทางประกาศว่าจบแล้ว แต่ bullet ยังเขียนเหมือนยังพังอยู่
                # (ใช้ lead_claim ด้วยเหตุผลเดียวกับ check 3 — ห้ามกวาดทั้งไฟล์)
                lead = lead_claim(tbody)
                if lead and not re.search(DONE, b, re.I):
                    out.append(f"- 🟡 `{os.path.basename(h)}` → `[[{target}]]` — หัวไฟล์ปลายทาง"
                               f"ประกาศว่าจบแล้ว แต่บรรทัด hub ไม่ได้บอก — **เทียบเอง**\n"
                               f"  > ไฟล์: `{lead[:110]}`\n"
                               f"  > hub: `{b.strip().splitlines()[0][:110]}`")
                    n += 1

# ── 5. ไฟล์ที่ไม่มีใครชี้ถึง — สาเหตุตรง ๆ ของการรื้อสร้างงานซ้ำ 2026-08-09 ────
idx = open(os.path.join(store, 'MEMORY.md'), encoding='utf-8').read()
reach = set(re.findall(r'\]\(([A-Za-z0-9._-]+)\.md\)', idx))
for h in hubs:
    reach |= set(re.findall(r'\[\[([A-Za-z0-9._-]+)\]\]', open(h, encoding='utf-8').read()))
    reach.add(os.path.basename(h)[:-3])
orphan = sorted(os.path.basename(f)[:-3] for f in files if os.path.basename(f)[:-3] not in reach)
for o in orphan:
    out.append(f"- 🔴 `{o}.md` — **ไม่มีบรรทัดใน MEMORY.md และไม่มี hub ไหนชี้ถึง** "
               f"(เซสชันที่ไม่ได้ยิงค้นจะไม่มีทางรู้ว่ามีไฟล์นี้)")
    n += 1

with open(report, 'a', encoding='utf-8') as fh:
    fh.write("\n## บรรทัดสรุป (description / hub) และไฟล์กำพร้า\n\n")
    fh.write(("\n".join(out) if out else
              f"ตรวจ {len(files)} ไฟล์ + hub {len(hubs)} ตัว — description ตรงกับเนื้อไฟล์ "
              "ทุกตัว, บรรทัด hub ไม่ขัดกับปลายทาง, ไม่มีไฟล์กำพร้า") + "\n")
print(n)
PY
SUMMARY_FINDINGS=$(python3 - "$REPORT" <<'PY'
import re,sys
t=open(sys.argv[1],encoding='utf-8').read()
sec=t.split('## บรรทัดสรุป (description / hub) และไฟล์กำพร้า',1)
print(len(re.findall(r'(?m)^- [🔴🟡🟠]', sec[1])) if len(sec)>1 else 0)
PY
)
FINDINGS=$((FINDINGS + SUMMARY_FINDINGS))

{
  echo "---"
  echo
  echo "## สรุป"
  echo
  echo "| | |"
  echo "|---|--:|"
  echo "| ไฟล์ที่ตรวจ (PR/path) | $N |"
  echo "| PR ที่ยืนยันกับ GitHub | $CHECKED_PR |"
  echo "| path ที่เช็คการมีอยู่ | $CHECKED_PATH |"
  echo "| description + hub + กำพร้า (ตรวจทั้งสโตร์) | $SUMMARY_FINDINGS |"
  echo "| **เรื่องที่ต้องดู** | **$FINDINGS** |"
  echo
  if [ "$FINDINGS" -eq 0 ]; then
    echo "ไม่พบความเพี้ยนในรอบนี้ — ทุก PR และ path ที่ตรวจตรงกับความจริงปัจจุบัน"
  else
    echo "⚠️ ทั้งหมดนี้เป็น **ข้อเสนอ** ให้เจ้าของตัดสิน — สคริปต์ไม่แก้ store เอง"
  fi
} >> "$REPORT"

echo "เสร็จ → $REPORT  (พบ $FINDINGS เรื่อง จาก $N ไฟล์)"
