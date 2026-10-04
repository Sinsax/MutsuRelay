//! 识别结果的文本后处理与结果队列。
//!
//! 处理顺序：清洗 → 长度/重复过滤 → **接缝去重** → 全局去重 → 敏感词（由调用方执行）。
//! 其中接缝去重是 P3 新增的：强制切段时下一段的 pre-roll 与上一段尾部重叠，
//! 同一段语音会被识别两次，表现为句子开头重复出现上一句的结尾。

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// 单条结果去重窗口。此前是 Rust 3s + Dart 2s 两层，正常复述同一句会被吞。
pub const DEDUP_WINDOW: Duration = Duration::from_millis(1500);
/// 接缝去重尝试匹配的最长字数
const SEAM_MAX_CHARS: usize = 12;
/// 接缝去重要求的最短匹配字数（低于此值不动，避免误删正常重复）
const SEAM_MIN_CHARS: usize = 3;

/// 去掉中文字符之间被 ASR 插入的空格，并裁掉首尾标点。
pub fn clean(text: &str) -> String {
    let raw: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    for i in 0..raw.len() {
        if raw[i] == ' ' && i > 0 && i + 1 < raw.len() && is_cjk(raw[i - 1]) && is_cjk(raw[i + 1]) {
            continue;
        }
        out.push(raw[i]);
    }
    out.trim_matches(|c: char| {
        matches!(
            c,
            '，' | '。' | '、' | '！' | '？' | '：' | '；' | '…' | '—' | '·' | ' ' | '.' | ','
        )
    })
    .to_string()
}

fn is_cjk(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c)
}

fn is_punct(c: char) -> bool {
    c.is_ascii_punctuation() || "。，！？；、：…—·「」『』“”‘’（）()\"'".contains(c)
}

/// 去掉标点与空白后的文本，用于长度判断与去重比较。
pub fn chars_only(text: &str) -> String {
    text.chars().filter(|c| !is_punct(*c) && !c.is_whitespace()).collect()
}

/// 单字占比过高 → 认为识别出了重复噪声（如「好好好好好」）。
pub fn is_repetitive(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() < 4 {
        return false;
    }
    let mut max_count = 0u32;
    let mut seen: Vec<(char, u32)> = Vec::new();
    for &c in &chars {
        if let Some(pos) = seen.iter().position(|&(ch, _)| ch == c) {
            seen[pos].1 += 1;
            max_count = max_count.max(seen[pos].1);
        } else {
            seen.push((c, 1));
            max_count = max_count.max(1);
        }
    }
    max_count as f32 / chars.len() as f32 > 0.55
}

/// 接缝去重：若 `cur` 的前缀与 `prev` 的后缀重复，去掉重复部分。
///
/// 只在重复字数 ≥ [`SEAM_MIN_CHARS`] 时生效；去重后长度不足 2 字则保持原样
/// （宁可有重复，也不要产出空句）。
pub fn trim_seam_overlap(prev: &str, cur: &str) -> String {
    let pc: Vec<char> = chars_only(prev).chars().collect();
    let cc: Vec<char> = chars_only(cur).chars().collect();
    if pc.len() < SEAM_MIN_CHARS || cc.len() < SEAM_MIN_CHARS {
        return cur.to_string();
    }
    let max_k = SEAM_MAX_CHARS.min(pc.len()).min(cc.len());
    let mut best = 0usize;
    for k in (SEAM_MIN_CHARS..=max_k).rev() {
        if pc[pc.len() - k..] == cc[..k] {
            best = k;
            break;
        }
    }
    if best == 0 {
        return cur.to_string();
    }
    // 在保留标点的原串上裁掉前 best 个字符（要求这段里没有标点，否则下标对不上）
    let cleaned: Vec<char> = cur.chars().collect();
    if best >= cleaned.len() {
        return cur.to_string();
    }
    if cleaned[..best].iter().any(|c| is_punct(*c)) {
        return cur.to_string();
    }
    let rest: String = cleaned[best..].iter().collect();
    let rest = clean(&rest);
    if rest.chars().filter(|c| !is_punct(*c)).count() < 2 {
        cur.to_string()
    } else {
        rest
    }
}

/// 把长句按标点切成适合弹幕/字幕的长度。
pub fn split_sentence(text: &str) -> Vec<String> {
    const SPLIT_MAX_LEN: usize = 15;
    if text.chars().count() <= SPLIT_MAX_LEN {
        return vec![text.to_string()];
    }

    let strong: &[char] = &['。', '！', '？', '\n'];
    let soft: &[char] = &['，', '；', '、', '：', '）', '」', '』', '"'];
    let particles: &[char] = &['的', '了', '在', '是', '我', '有', '和', '就', '不', '人'];

    let chars: Vec<char> = text.chars().collect();
    let mut parts: Vec<String> = Vec::new();
    let mut start = 0;

    while start < chars.len() {
        let remaining = chars.len() - start;
        if remaining <= SPLIT_MAX_LEN {
            parts.push(chars[start..].iter().collect());
            break;
        }

        let search_end = (start + SPLIT_MAX_LEN).min(chars.len());
        let mut best = search_end;

        if let Some(pos) = chars[start..search_end].iter().rposition(|c| strong.contains(c)) {
            best = start + pos + 1;
        } else if let Some(pos) = chars[start..search_end].iter().rposition(|c| soft.contains(c)) {
            best = start + pos + 1;
        } else {
            let third = start + (search_end - start) * 2 / 3;
            if let Some(pos) = chars[third..search_end]
                .iter()
                .rposition(|c| particles.contains(c))
            {
                best = third + pos + 1;
            }
        }

        parts.push(chars[start..best].iter().collect());
        start = best;

        while start < chars.len()
            && (chars[start].is_whitespace() || matches!(chars[start], ' ' | '　' | '、'))
        {
            start += 1;
        }
    }

    parts
}

/// 逐条结果的过滤流水线。持有跨段状态（接缝前文、去重窗口）。
pub struct TextPipeline {
    /// 上一条最终结果（归一化文本）与时间
    last_dedup: Option<(String, Instant)>,
    /// 上一条最终产出文本（保留标点），用于接缝去重
    last_final: String,
    dedup_window: Duration,
    /// 统计
    pub rejected_short: u64,
    pub rejected_repetitive: u64,
    pub rejected_dup: u64,
    pub seam_trimmed: u64,
}

impl Default for TextPipeline {
    fn default() -> Self {
        Self::new(DEDUP_WINDOW)
    }
}

impl TextPipeline {
    pub fn new(dedup_window: Duration) -> Self {
        Self {
            last_dedup: None,
            last_final: String::new(),
            dedup_window,
            rejected_short: 0,
            rejected_repetitive: 0,
            rejected_dup: 0,
            seam_trimmed: 0,
        }
    }

    pub fn reset(&mut self) {
        self.last_dedup = None;
        self.last_final.clear();
    }

    /// 处理一段识别结果。返回 `None` 表示该结果应被丢弃。
    ///
    /// `seam_overlap_ms` > 0 表示本段的起始音频与上一段结尾重叠（强制切段造成），
    /// 这时才做前缀去重，避免误删正常的重复语句。
    ///
    /// **只处理正式段**。interim（实时半句）在 `asr::decode_batch` 更早处就分流了 ——
    /// 它不写字幕、不触发发言，也**绝不能碰这里的去重状态**（否则半句会污染正式结果的
    /// 去重窗口）。因此本函数没有 `is_final` 参数：它默认就是 final 语义。
    pub fn accept(&mut self, raw: &str, seam_overlap_ms: u32) -> Option<String> {
        let cleaned = clean(raw);
        if cleaned.is_empty() {
            self.rejected_short += 1;
            return None;
        }
        let norm = chars_only(&cleaned);
        if norm.chars().count() < 2 {
            self.rejected_short += 1;
            return None;
        }
        if is_repetitive(&norm) {
            self.rejected_repetitive += 1;
            return None;
        }

        let mut text = cleaned;
        if seam_overlap_ms > 0 && !self.last_final.is_empty() {
            let trimmed = trim_seam_overlap(&self.last_final, &text);
            if trimmed != text {
                self.seam_trimmed += 1;
                text = trimmed;
            }
        }

        let norm = chars_only(&text);
        if norm.chars().count() < 2 {
            self.rejected_short += 1;
            return None;
        }

        if let Some((prev, at)) = &self.last_dedup {
            if *prev == norm && at.elapsed() < self.dedup_window {
                self.rejected_dup += 1;
                return None;
            }
        }
        self.last_dedup = Some((norm, Instant::now()));
        self.last_final = text.clone();

        Some(text)
    }
}

/// 识别结果队列。追加语义（不是覆盖），UI 一次取走一整批。
pub struct ResultQueue {
    inner: Mutex<VecDeque<serde_json::Value>>,
    max: usize,
    dropped: AtomicU64,
    total: AtomicU64,
}

impl ResultQueue {
    pub fn new(max: usize) -> Self {
        Self {
            inner: Mutex::new(VecDeque::new()),
            max,
            dropped: AtomicU64::new(0),
            total: AtomicU64::new(0),
        }
    }

    /// 追加。超出上限时丢最旧的并计数（宁可丢也不让消费端追不上）。
    pub fn push(&self, value: serde_json::Value) {
        if let Ok(mut q) = self.inner.lock() {
            q.push_back(value);
            while q.len() > self.max {
                q.pop_front();
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
        self.total.fetch_add(1, Ordering::Relaxed);
    }

    pub fn drain(&self) -> Vec<serde_json::Value> {
        self.inner
            .lock()
            .map(|mut q| q.drain(..).collect())
            .unwrap_or_default()
    }

    pub fn len(&self) -> usize {
        self.inner.lock().map(|q| q.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn dropped(&self) -> u64 {
        self.dropped.load(Ordering::Relaxed)
    }

    pub fn total(&self) -> u64 {
        self.total.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_removes_inner_cjk_spaces() {
        assert_eq!(clean("今天 天气 不错"), "今天天气不错");
        // ASCII 之间的空格要保留
        assert_eq!(clean("说 OK 吧"), "说 OK 吧");
    }

    #[test]
    fn clean_trims_edge_punctuation() {
        assert_eq!(clean("，你好。"), "你好");
        assert_eq!(clean("。。。"), "");
    }

    #[test]
    fn repetitive_detection() {
        assert!(is_repetitive("好好好好好好"));
        assert!(!is_repetitive("今天天气不错"));
        assert!(!is_repetitive("哈"));
    }

    #[test]
    fn split_short_text_unchanged() {
        assert_eq!(split_sentence("你好"), vec!["你好".to_string()]);
    }

    #[test]
    fn split_long_text_at_punctuation() {
        let t = "今天我们来聊一聊这个非常有名的项目，它主要做的事情是把语音转成文字，然后发到直播间里。";
        let parts = split_sentence(t);
        assert!(parts.len() > 1);
        for p in &parts {
            assert!(p.chars().count() <= 15, "过长的片段: {p}");
        }
        assert_eq!(parts.concat(), t);
    }

    #[test]
    fn seam_trim_removes_duplicated_prefix() {
        let prev = "今天天气不错我们出去走走";
        let cur = "我们出去走走然后吃饭";
        assert_eq!(trim_seam_overlap(prev, cur), "然后吃饭");
    }

    #[test]
    fn seam_trim_ignores_short_overlap() {
        let prev = "今天天气不错";
        let cur = "错不了";
        // 只有 1 个字重叠 → 不动
        assert_eq!(trim_seam_overlap(prev, cur), "错不了");
    }

    #[test]
    fn seam_trim_leaves_unrelated_text() {
        let prev = "今天天气不错";
        let cur = "我们出去吃饭";
        assert_eq!(trim_seam_overlap(prev, cur), "我们出去吃饭");
    }

    #[test]
    fn seam_trim_keeps_something_when_fully_contained() {
        let prev = "今天天气不错我们出去走走";
        let cur = "我们出去走走";
        // 完全被包含 → 不应产出空串
        assert_eq!(trim_seam_overlap(prev, cur), "我们出去走走");
    }

    #[test]
    fn pipeline_rejects_short_and_repetitive() {
        let mut p = TextPipeline::default();
        assert!(p.accept("啊", 0).is_none());
        assert!(p.accept("好好好好好好", 0).is_none());
        assert!(p.accept("今天天气不错", 0).is_some());
    }

    #[test]
    fn pipeline_dedups_within_window() {
        let mut p = TextPipeline::new(Duration::from_millis(50));
        assert!(p.accept("今天天气不错", 0).is_some());
        // 只差一个逗号也应被认作重复（比较归一化文本）
        assert!(p.accept("今天天气不错，", 0).is_none());
        std::thread::sleep(Duration::from_millis(80));
        assert!(p.accept("今天天气不错", 0).is_some(), "超出窗口应放行");
    }

    #[test]
    fn pipeline_applies_seam_trim_only_when_marked() {
        let mut p = TextPipeline::new(Duration::from_millis(0));
        p.accept("今天天气不错我们出去走走", 0);
        // 标记了接缝重叠 → 去掉重复前缀
        let got = p.accept("我们出去走走然后吃饭", 300).unwrap();
        assert_eq!(got, "然后吃饭");

        let mut p2 = TextPipeline::new(Duration::from_millis(0));
        p2.accept("今天天气不错我们出去走走", 0);
        // 未标记 → 原样保留（可能是正常的复述）
        let got2 = p2.accept("我们出去走走然后吃饭", 0).unwrap();
        assert_eq!(got2, "我们出去走走然后吃饭");
    }

    #[test]
    fn final_stage_dedups_within_window() {
        // interim 不再走 `accept`（它在 asr::decode_batch 就被分流），所以这里只钉
        // final 语义：窗口内的复述被吞掉，超出窗口才放行。
        let mut p = TextPipeline::default();
        assert!(p.accept("今天天气", 0).is_some());
        assert!(p.accept("今天天气", 0).is_none(), "窗口内的复述应被去重");
    }

    #[test]
    fn result_queue_overflow_drops_oldest() {
        let q = ResultQueue::new(3);
        for i in 0..5 {
            q.push(serde_json::json!({ "i": i }));
        }
        assert_eq!(q.len(), 3);
        assert_eq!(q.dropped(), 2);
        assert_eq!(q.total(), 5);
        let items = q.drain();
        assert_eq!(items[0]["i"], 2);
        assert_eq!(items[2]["i"], 4);
        assert!(q.is_empty());
    }
}
