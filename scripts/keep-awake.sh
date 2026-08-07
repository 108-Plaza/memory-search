#!/usr/bin/env bash
# ให้เครื่องตื่นตลอดตอนเสียบไฟ แต่ปล่อยให้ "จอ" ดับได้ — สำหรับงานขุด memory ตี 3
#
#   sudo ./keep-awake.sh on       เปิด: จอดับ 10 นาที, เครื่องไม่หลับ (เฉพาะตอนเสียบไฟ)
#   sudo ./keep-awake.sh off      คืนค่าเดิม (sleep 1 / displaysleep 180)
#        ./keep-awake.sh status   ดูค่าปัจจุบัน (ไม่ต้อง sudo)
#
# ทำอะไรบ้าง (เฉพาะ AC เท่านั้น — ใช้แบตอยู่ยังหลับปกติ ไม่กินแบตทิ้ง):
#   sleep 0         เครื่องไม่หลับเอง
#   displaysleep 10 จอดับหลังว่าง 10 นาที (ประหยัดไฟ/ถนอมจอ — เครื่องยังทำงาน)
#   disksleep 0     ดิสก์ไม่หลับ กัน I/O สะดุดตอนขุด
#   + ตั้ง wake ประจำวัน 02:55 เป็นตาข่ายรองรับ เผื่อมีอะไรสั่งให้หลับ
#
# ⚠️ MacBook: "ปิดฝา" ยังหลับอยู่ดี (clamshell sleep) — pmset สั่งไม่ได้
#    ถ้าจะให้รันข้ามคืน ให้ "เปิดฝาทิ้งไว้แล้วปล่อยจอดับ" อย่าปิดฝา

set -euo pipefail

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ต้องรันด้วย sudo:  sudo $0 $1" >&2
    exit 1
  fi
}

status() {
  echo "=== AC Power (ตอนเสียบไฟ) ==="
  pmset -g custom | awk '/^AC Power/{f=1;next} /^[A-Za-z]/{if(f&&!/^ /)f=0} f' \
    | grep -E ' (sleep|displaysleep|disksleep) ' || true
  echo
  echo "=== wake ที่ตั้งไว้ ==="
  pmset -g sched | grep -i 'repeat' || echo " (ไม่มี repeating wake)"
  echo
  echo "=== ตอนนี้มีอะไรกันเครื่องหลับอยู่ไหม ==="
  pmset -g assertions | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep' | head -5 || true
}

case "${1:-status}" in
  on)
    need_root on
    pmset -c sleep 0
    pmset -c displaysleep 10
    pmset -c disksleep 0
    # ตาข่ายรองรับ: ตื่นทุกวัน 02:55 ก่อนงานขุดตี 3
    pmset repeat wakeorpoweron MTWRFSU 02:55:00
    echo "✅ เปิดแล้ว — จอดับ 10 นาที เครื่องไม่หลับ (เฉพาะตอนเสียบไฟ) + ตื่นทุกวัน 02:55"
    echo
    status
    ;;
  off)
    need_root off
    pmset -c sleep 1
    pmset -c displaysleep 180
    pmset -c disksleep 10
    pmset repeat cancel
    echo "✅ คืนค่าเดิมแล้ว (sleep 1 / displaysleep 180 / disksleep 10, ยกเลิก repeating wake)"
    echo
    status
    ;;
  status) status ;;
  *) echo "ใช้: $0 {on|off|status}" >&2; exit 1 ;;
esac
