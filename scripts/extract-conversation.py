#!/usr/bin/env python3
"""แปลง transcript .jsonl ของ Claude Code เป็นบทสนทนาอ่านง่าย (deterministic layer ของ miner)

ใช้: extract-conversation.py <transcript.jsonl> [max_chars_per_turn]
เอาเฉพาะ role user/assistant ข้าม tool result ใหญ่ ๆ — สิ่งที่ miner ต้องการคือ
การตัดสินใจ/ข้อสรุป ซึ่งอยู่ในข้อความ ไม่ใช่ใน tool output ดิบ
"""
import json
import sys

path = sys.argv[1]
cap = int(sys.argv[2]) if len(sys.argv) > 2 else 1500

for line in open(path):
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("type") not in ("user", "assistant"):
        continue
    m = d.get("message", {})
    c = m.get("content")
    if isinstance(c, str):
        text = c
    elif isinstance(c, list):
        text = " ".join(
            b.get("text", "")
            for b in c
            if isinstance(b, dict) and b.get("type") == "text"
        )
    else:
        continue
    text = text.strip()
    if not text:
        continue
    role = "U" if m.get("role") == "user" else "A"
    print(f"{role}: {text[:cap]}")
