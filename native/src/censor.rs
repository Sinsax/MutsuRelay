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
    let mut result = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        let mut matched = false;
        for word in &words {
            if word.is_empty() {
                continue;
            }
            let word_chars: Vec<char> = word.chars().collect();
            let wlen = word_chars.len();
            if i + wlen > chars.len() {
                continue;
            }
            if chars[i..i + wlen] != word_chars[..] {
                continue;
            }

            let replacement = if mode == 2 {
                to_initials(word)
            } else {
                "[***]".to_string()
            };
            result.push_str(&replacement);
            i += wlen;
            matched = true;
            break;
        }
        if !matched {
            result.push(chars[i]);
            i += 1;
        }
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
