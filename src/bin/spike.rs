// Spike: prove a multilingual embedding model handles Thai↔English memory
// retrieval on this machine before building anything on top of it.
//
// Test shape: 8 real passages lifted from the pos108 memory store (mixed
// Thai/English, the actual register the store is written in), 6 queries the
// owner would realistically type (Thai and English), each with one correct
// answer. A model passes when the correct passage ranks #1; near-misses
// report rank so we can judge.

use anyhow::Result;
use fastembed::{EmbeddingModel, InitOptions, TextEmbedding};
use std::time::Instant;

const PASSAGES: &[(&str, &str)] = &[
    (
        "promptpay",
        "Branch PromptPay: manual ทวนยอด inside shift-close is the money-in source of \
         truth; both automatic ingest paths are merged and deliberately dark. Email \
         ingest cancelled because KBank sends no money-in alert emails.",
    ),
    (
        "tenant-crashloop",
        "Tenant CrashLoop root cause: TENANT_IMAGE_TAG skew — the control plane migrates \
         the DB to a schema newer than the tenant image, so the tenant pod boots against \
         a future schema and dies.",
    ),
    (
        "backup-gap",
        "Tenant DB backup gap: shops and the control plane live on a docker Postgres on \
         port 5433 which had ZERO backups; tenant-dump.sh now covers it with 2h and \
         nightly crons writing /srv/pg-backups/tenants/.",
    ),
    (
        "kiosk-thai",
        "Bare-console kiosk till: Thai tone marks (วรรณยุกต์ลอย) float when rendered by \
         the software renderer; the fix is SLINT_BACKEND=linuxkms with the Skia/DRM \
         renderer chain and libseat for DRM master — never -noseat.",
    ),
    (
        "head-office",
        "MAIN = สำนักงานใหญ่ ไม่นับโควตาสาขา; BR01..BRnn are auto-created at provision \
         time. Old shops are not backfilled.",
    ),
    (
        "release-prod",
        "core deploy: deploy/staging reaches staging only since #788; production is \
         git push origin main:release/prod which rolls the control plane AND every \
         tenants/t-* shop — real customers.",
    ),
    (
        "escpos",
        "ESC/POS Thai encoding fixed in core#771: kitchen slips print Thai via codepage \
         TIS-620 mapping on the branch server; untested on real hardware.",
    ),
    (
        "quota",
        "Terminal quota: max_terminals is enforced at sale-pay time via the entitlement \
         layer above RBAC, fail-open with a 30s cache.",
    ),
];

const QUERIES: &[(&str, &str)] = &[
    ("ทำไม tenant พัง CrashLoop ตลอด", "tenant-crashloop"),
    ("พร้อมเพย์ ต่อสาขา ทวนยอดยังไง", "promptpay"),
    ("สระลอย วรรณยุกต์ลอย บนจอ kiosk แก้ยังไง", "kiosk-thai"),
    (
        "deploy ขึ้น production ร้านค้าจริง ใช้ branch ไหน",
        "release-prod",
    ),
    ("database ร้านค้า ไม่มี backup", "backup-gap"),
    ("limit จำนวนเครื่อง POS ต่อร้าน", "quota"),
];

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let dot: f32 = a.iter().zip(b).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    dot / (na * nb)
}

fn run(model: EmbeddingModel, name: &str, query_prefix: &str, passage_prefix: &str) -> Result<()> {
    println!("===== {name} =====");
    let t0 = Instant::now();
    let mut m = TextEmbedding::try_new(InitOptions::new(model).with_show_download_progress(false))?;
    println!("  init (incl. download ครั้งแรก): {:?}", t0.elapsed());

    let t1 = Instant::now();
    let passage_texts: Vec<String> = PASSAGES
        .iter()
        .map(|(_, p)| format!("{passage_prefix}{p}"))
        .collect();
    let p_emb = m.embed(passage_texts, None)?;
    println!(
        "  embed {} passages: {:?}  (dim={})",
        PASSAGES.len(),
        t1.elapsed(),
        p_emb[0].len()
    );

    let mut correct = 0;
    for (q, want) in QUERIES {
        let t2 = Instant::now();
        let q_emb = &m.embed(vec![format!("{query_prefix}{q}")], None)?[0];
        let mut scored: Vec<(usize, f32)> = p_emb
            .iter()
            .enumerate()
            .map(|(i, p)| (i, cosine(q_emb, p)))
            .collect();
        scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
        let got = PASSAGES[scored[0].0].0;
        let rank = scored
            .iter()
            .position(|(i, _)| PASSAGES[*i].0 == *want)
            .unwrap()
            + 1;
        let mark = if got == *want {
            correct += 1;
            "✅"
        } else {
            "❌"
        };
        println!(
            "  {mark} [{:>6.1?}] top={got:<16} (ถูก={want}, rank={rank}, score#1={:.3}, margin={:+.3}) «{q}»",
            t2.elapsed(),
            scored[0].1,
            scored[0].1 - scored[1].1,
        );
    }
    println!("  ==> {correct}/{} ถูกอันดับ 1\n", QUERIES.len());
    Ok(())
}

fn main() -> Result<()> {
    // เรียงจากเล็กไปใหญ่ — ถ้าตัวเล็กเอาอยู่ ไม่ต้องจ่ายราคาตัวใหญ่
    run(
        EmbeddingModel::MultilingualE5Small,
        "multilingual-e5-small (~470MB)",
        "query: ",
        "passage: ",
    )?;
    run(EmbeddingModel::BGEM3, "bge-m3 (~2.2GB)", "", "")?;
    Ok(())
}
