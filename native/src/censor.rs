use pinyin::ToPinyin;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};

/// 屏蔽词表。预先字符化并按字符数降序，另建首字索引，
/// 避免"词数 × 文本长度"的全扫描。
struct Blocklist {
    words: Vec<Vec<char>>,
    by_first: HashMap<char, Vec<usize>>,
}

impl Blocklist {
    fn build(words: Vec<String>) -> Self {
        let words: Vec<Vec<char>> = words.iter().map(|w| w.chars().collect()).collect();
        let mut by_first: HashMap<char, Vec<usize>> = HashMap::new();
        for (i, w) in words.iter().enumerate() {
            if let Some(&first) = w.first() {
                by_first.entry(first).or_default().push(i);
            }
        }
        Self { words, by_first }
    }

    fn is_empty(&self) -> bool {
        self.words.is_empty()
    }
}

fn blocklist() -> &'static Mutex<Arc<Blocklist>> {
    static BLOCKLIST: OnceLock<Mutex<Arc<Blocklist>>> = OnceLock::new();
    BLOCKLIST.get_or_init(|| Mutex::new(Arc::new(Blocklist::build(Vec::new()))))
}

fn get_storage_path() -> std::path::PathBuf {
    super::bilive::get_storage_dir().join("blocklist.txt")
}

fn get_bundled_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?;
    Some(dir.join("asr").join("blocklist.txt"))
}

fn load_from_file(path: &std::path::Path) -> Vec<String> {
    std::fs::read_to_string(path)
        .map(|s| {
            s.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

fn to_initials(word: &str) -> String {
    word.to_pinyin()
        .filter_map(|p| p.map(|py| py.plain().chars().next().unwrap_or(' ')))
        .collect()
}

fn to_full_pinyin(word: &str) -> String {
    word.to_pinyin()
        .filter_map(|p| p.map(|py| py.plain().to_string()))
        .collect()
}

pub fn censor(text: &str, mode: i32) -> String {
    if mode == 0 {
        return text.to_string();
    }

    // lazy init: ensure blocklist is loaded (copies from bundled if needed)
    if blocklist().lock().map(|w| w.is_empty()).unwrap_or(true) {
        reload_blocklist();
    }

    let bl = blocklist().lock().unwrap().clone();
    if bl.is_empty() {
        return text.to_string();
    }

    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    if n == 0 {
        return String::new();
    }

    // Phase 1: 收集所有命中区间。只检查"首字相同"的词，不再全表扫描。
    let mut matches: Vec<(usize, usize)> = Vec::new();
    for i in 0..n {
        let Some(cands) = bl.by_first.get(&chars[i]) else { continue; };
        for &wi in cands {
            let wc = &bl.words[wi];
            let wlen = wc.len();
            if wlen == 0 || i + wlen > n {
                continue;
            }
            if chars[i..i + wlen] == wc[..] {
                matches.push((i, i + wlen));
            }
        }
    }
    if matches.is_empty() {
        return text.to_string();
    }

    // Phase 2: sort by start position, then merge overlapping spans
    matches.sort_unstable();
    let mut spans: Vec<(usize, usize)> = Vec::new();
    for (s, e) in matches {
        if let Some(last) = spans.last_mut() {
            if s <= last.1 {
                last.1 = last.1.max(e);
            } else {
                spans.push((s, e));
            }
        } else {
            spans.push((s, e));
        }
    }

    // Phase 3: build result, replacing each span
    // 替换规则按"每个命中片段"独立判断，与该片段在整句中的位置无关：
    //   2 字以内的词 → 全拼；更长的词 → 首字母。
    // 此前是"整句恰好等于 2 字屏蔽词才用全拼"的整句特例，导致同一个词在不同
    // 上下文里被替换成不同结果。
    let mut result = String::with_capacity(text.len());
    let mut pos = 0;
    for (start, end) in spans {
        for &c in &chars[pos..start] {
            result.push(c);
        }
        let span_text: String = chars[start..end].iter().collect();
        let replacement = if mode == 2 {
            if end - start <= 2 {
                to_full_pinyin(&span_text)
            } else {
                to_initials(&span_text)
            }
        } else {
            "[***]".to_string()
        };
        result.push_str(&replacement);
        pos = end;
    }
    for &c in &chars[pos..] {
        result.push(c);
    }
    result
}

pub fn reload_blocklist() {
    let storage = get_storage_path();
    let mut loaded = if storage.exists() {
        load_from_file(&storage)
    } else if let Some(bundled) = get_bundled_path() {
        if bundled.exists() {
            let words = load_from_file(&bundled);
            let _ = std::fs::copy(&bundled, &storage);
            words
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };

    // 去重：原来只按长度排序后调用 dedup()，相同词并不相邻，去重实际无效。
    let mut seen: HashSet<String> = HashSet::new();
    loaded.retain(|w| seen.insert(w.clone()));
    // 按"字符数"降序（原来用字节长度：纯中文时 3 字节/字刚好等价，混入 ASCII 就会排错）
    loaded.sort_by(|a, b| b.chars().count().cmp(&a.chars().count()));

    let count = loaded.len();
    if let Ok(mut w) = blocklist().lock() {
        *w = Arc::new(Blocklist::build(loaded));
    }
    log::info!("Blocklist reloaded: {count} words");
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 这些用例共享全局 blocklist，并行执行会互相覆盖。用锁把 setup 串起来，
    /// 返回的 guard 必须在用例结束前一直持有（所以调用点写作 let _g = setup(...)）。
    fn setup(words: Vec<&str>) -> std::sync::MutexGuard<'static, ()> {
        static TEST_LOCK: Mutex<()> = Mutex::new(());
        let guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        if let Ok(mut w) = blocklist().lock() {
            *w = Arc::new(Blocklist::build(words.iter().map(|s| s.to_string()).collect()));
        }
        guard
    }

    #[test]
    fn test_overlap_pinyin() {
        let _g = setup(vec!["操你", "你妈"]);
        assert_eq!(censor("操你妈", 2), "cnm");
    }

    #[test]
    fn test_overlap_asterisk() {
        let _g = setup(vec!["操你", "你妈"]);
        assert_eq!(censor("操你妈", 1), "[***]");
    }

    #[test]
    fn test_non_overlap() {
        let _g = setup(vec!["傻逼", "废物"]);
        // 中间隔字才是真正的"不相邻"，各自独立替换。
        // （相邻的屏蔽词会被合并成一个 span，见 test_adjacent_words_merge_into_one_span）
        assert_eq!(censor("你个傻逼真废物", 2), "你个shabi真feiwu");
    }

    #[test]
    fn test_adjacent_words_merge_into_one_span() {
        let _g = setup(vec!["傻逼", "废物"]);
        assert_eq!(censor("你个傻逼废物", 2), "你个sbfw");
    }

    #[test]
    fn test_mode_off() {
        assert_eq!(censor("操你妈", 0), "操你妈");
    }

    #[test]
    fn test_no_match() {
        let _g = setup(vec!["操你", "你妈"]);
        assert_eq!(censor("你好世界", 2), "你好世界");
    }

    #[test]
    fn test_adjacent_merge() {
        let _g = setup(vec!["操你", "娘逼"]);
        assert_eq!(censor("操你娘逼", 2), "cnnb");
    }

    #[test]
    fn test_multi_overlap() {
        let _g = setup(vec!["操你妈", "你妈逼"]);
        assert_eq!(censor("操你妈逼", 2), "cnmb");
    }

    #[test]
    fn test_full_pinyin_two_char() {
        let _g = setup(vec!["弱智"]);
        assert_eq!(censor("弱智", 2), "ruozhi");
    }

    #[test]
    fn test_full_pinyin_two_char_asterisk() {
        let _g = setup(vec!["傻逼"]);
        assert_eq!(censor("傻逼", 1), "[***]");
    }

    #[test]
    fn test_initials_three_char() {
        let _g = setup(vec!["操你妈"]);
        assert_eq!(censor("操你妈", 2), "cnm");
    }

    #[test]
    fn test_partial_full_pinyin_not_full_coverage() {
        let _g = setup(vec!["废物"]);
        assert_eq!(censor("你个废物", 2), "你个feiwu");
    }

    /// 逐片段规则的核心保证：同一个词在任何上下文里替换结果一致。
    #[test]
    fn test_same_word_consistent_across_contexts() {
        let _g = setup(vec!["弱智"]);
        assert_eq!(censor("弱智", 2), "ruozhi");
        assert_eq!(censor("你个弱智", 2), "你个ruozhi");
        assert_eq!(censor("弱智吧你", 2), "ruozhi吧你");
    }

    /// 首字索引：命中结果必须与全表扫描等价。
    #[test]
    fn test_first_char_index_finds_all() {
        let _g = setup(vec!["傻逼", "傻狗", "操你妈", "废物"]);
        assert_eq!(censor("你个傻狗和傻逼", 1), "你个[***]和[***]");
    }

    /// 重复词不得改变结果（原来 dedup 实际无效）。
    #[test]
    fn test_duplicate_words_are_harmless() {
        let _g = setup(vec!["傻逼", "傻逼", "废物"]);
        assert_eq!(censor("你个傻逼废物", 1), "你个[***]");
    }
}
