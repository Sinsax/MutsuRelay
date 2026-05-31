use pinyin::ToPinyin;
use std::sync::Mutex;

static BLOCKLIST: Mutex<Vec<String>> = Mutex::new(Vec::new());

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

pub fn censor(text: &str, mode: i32) -> String {
    if mode == 0 {
        return text.to_string();
    }

    // lazy init: ensure blocklist is loaded (copies from bundled if needed)
    if BLOCKLIST.lock().map(|w| w.is_empty()).unwrap_or(true) {
        reload_blocklist();
    }

    let words = BLOCKLIST.lock().map(|w| w.clone()).unwrap_or_default();
    if words.is_empty() {
        return text.to_string();
    }

    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    if n == 0 {
        return String::new();
    }

    // Phase 1: find all match positions (start, end) for all words
    let mut matches: Vec<(usize, usize)> = Vec::new();
    for word in &words {
        if word.is_empty() {
            continue;
        }
        let wc: Vec<char> = word.chars().collect();
        let wlen = wc.len();
        if wlen > n {
            continue;
        }
        for i in 0..=n - wlen {
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
    let mut result = String::with_capacity(text.len());
    let mut pos = 0;
    for (start, end) in spans {
        for &c in &chars[pos..start] {
            result.push(c);
        }
        let span_text: String = chars[start..end].iter().collect();
        let replacement = if mode == 2 {
            to_initials(&span_text)
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

    // Deduplicate and sort by length descending to avoid sub-word collisions
    loaded.sort_by(|a, b| b.len().cmp(&a.len()));
    loaded.dedup();

    if let Ok(mut w) = BLOCKLIST.lock() {
        *w = loaded;
    }
    log::info!("Blocklist reloaded");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup(words: Vec<&str>) {
        if let Ok(mut w) = BLOCKLIST.lock() {
            *w = words.iter().map(|s| s.to_string()).collect();
        }
    }

    #[test]
    fn test_overlap_pinyin() {
        setup(vec!["操你", "你妈"]);
        assert_eq!(censor("操你妈", 2), "cnm");
    }

    #[test]
    fn test_overlap_asterisk() {
        setup(vec!["操你", "你妈"]);
        assert_eq!(censor("操你妈", 1), "[***]");
    }

    #[test]
    fn test_non_overlap() {
        setup(vec!["傻逼", "废物"]);
        assert_eq!(censor("你个傻逼废物", 2), "你个sbfw");
    }

    #[test]
    fn test_mode_off() {
        assert_eq!(censor("操你妈", 0), "操你妈");
    }

    #[test]
    fn test_no_match() {
        setup(vec!["操你", "你妈"]);
        assert_eq!(censor("你好世界", 2), "你好世界");
    }

    #[test]
    fn test_adjacent_merge() {
        setup(vec!["操你", "娘逼"]);
        assert_eq!(censor("操你娘逼", 2), "cnnb");
    }

    #[test]
    fn test_multi_overlap() {
        setup(vec!["操你妈", "你妈逼"]);
        assert_eq!(censor("操你妈逼", 2), "cnmb");
    }
}
