use memory_search::{Index, STORE};
fn main() -> anyhow::Result<()> {
    let t = std::time::Instant::now();
    let mut idx = Index::build(std::path::Path::new(STORE))?;
    eprintln!("index: {} chunks in {:?}", idx.chunks.len(), t.elapsed());
    for q in [
        "ทำไม tenant CrashLoop",
        "PromptPay ต่อสาขา ทวนยอด",
        "RESEND_API_KEY ยัง revoke ไม่เสร็จ",
        "who reads audit_logs",
    ] {
        let t = std::time::Instant::now();
        let hits = idx.search(q, 3)?;
        eprintln!("\n« {q} »  ({:?})", t.elapsed());
        for (s, c) in hits {
            eprintln!(
                "  {s:.3}  {} — {}",
                c.file,
                if c.heading.is_empty() {
                    "(top)"
                } else {
                    &c.heading
                }
            );
        }
    }
    Ok(())
}
