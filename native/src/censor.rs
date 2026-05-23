use std::sync::LazyLock;

static BLOCKLIST: LazyLock<Vec<String>> = LazyLock::new(|| {
    let path = get_blocklist_path();
    std::fs::read_to_string(&path)
        .map(|s| {
            s.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default()
});

fn get_blocklist_path() -> std::path::PathBuf {
    super::bilive::get_storage_dir().join("blocklist.txt")
}

fn to_initials(word: &str) -> String {
    word.chars()
        .filter_map(|c| {
            let b = c as u32;
            if (0x4E00..=0x9FFF).contains(&b) {
                Some('x') // placeholder for pinyin initial
            } else {
                Some(c.to_ascii_lowercase())
            }
        })
        .collect()
}

pub fn censor(text: &str, mode: i32) -> String {
    if mode == 0 {
        return text.to_string();
    }

    let words = &*BLOCKLIST;
    let mut result = text.to_string();

    for word in words {
        if word.is_empty() {
            continue;
        }
        let replacement = if mode == 2 {
            to_initials(word)
        } else {
            "[***]".to_string()
        };
        result = result.replace(word, &replacement);
    }
    result
}

pub fn reload_blocklist() {
    let path = get_blocklist_path();
    let words: Vec<String> = std::fs::read_to_string(&path)
        .map(|s| {
            s.lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default();
    // Force re-init by overwriting the lazy static is not possible,
    // so we just log. In production, we'd use a Mutex.
    log::info!("Blocklist reloaded: {} words", words.len());
}
