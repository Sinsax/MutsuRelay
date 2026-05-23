use reqwest::header::{COOKIE, SET_COOKIE};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

static COOKIE_TEXT: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));
static CONNECTED: AtomicBool = AtomicBool::new(false);
static COOKIE_VALID: AtomicBool = AtomicBool::new(false);
static ROOM_ID: LazyLock<Mutex<u64>> = LazyLock::new(|| Mutex::new(0));
static LANGUAGE: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new("auto".to_string()));
static CLOSE_BEHAVIOR: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new("hide".to_string()));
static USER_INFO: LazyLock<Mutex<Option<UserInfo>>> = LazyLock::new(|| Mutex::new(None));
static LAST_ERROR: LazyLock<Mutex<String>> = LazyLock::new(|| Mutex::new(String::new()));

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UserInfo {
    pub mid: u64,
    pub uname: String,
    pub is_login: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct QrCodeResult {
    pub status: String,
    pub cookie: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub roomid: u64,
    #[serde(default)]
    pub sessdata: String,
    #[serde(default)]
    pub bili_jct: String,
    #[serde(default)]
    pub dede_user_id: String,
    #[serde(default)]
    pub dede_user_id_ckmd5: String,
    #[serde(default)]
    pub buvid3: String,
    #[serde(default = "default_noise_gate")]
    pub noise_gate: f32,
    #[serde(default = "default_censor_mode")]
    pub censor_mode: i32,
    #[serde(default = "default_noise_suppress")]
    pub noise_suppress: bool,
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(default = "default_close_behavior")]
    pub close_behavior: String,
}

#[derive(Clone, Debug, Default)]
struct Account {
    dede_user_id: String,
    dede_user_id_ckmd5: String,
    sessdata: String,
    bili_jct: String,
    buvid3: String,
}

fn default_noise_gate() -> f32 { 0.01 }
fn default_censor_mode() -> i32 { 0 }
fn default_noise_suppress() -> bool { true }
fn default_language() -> String { "auto".to_string() }
fn default_close_behavior() -> String { "hide".to_string() }

fn runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Runtime::new().map_err(|e| format!("创建异步运行时失败: {e}"))
}

fn set_last_error(message: impl Into<String>) {
    if let Ok(mut error) = LAST_ERROR.lock() {
        *error = message.into();
    }
}

fn clear_last_error() {
    if let Ok(mut error) = LAST_ERROR.lock() {
        error.clear();
    }
}

pub fn get_last_error() -> String {
    LAST_ERROR.lock().map(|error| error.clone()).unwrap_or_default()
}

pub fn get_config_path() -> PathBuf {
    get_storage_dir().join("config.toml")
}

impl Config {
    pub fn load() -> Result<Self, String> {
        let path = get_config_path();
        if !path.exists() {
            return Ok(Self::default());
        }
        let content = fs::read_to_string(&path)
            .map_err(|e| format!("读取配置失败: {}", e))?;
        toml::from_str(&content).map_err(|e| format!("解析配置失败: {}", e))
    }

    pub fn save(&self) -> Result<(), String> {
        let path = get_config_path();
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("创建配置目录失败: {}", e))?;
        }
        let text = toml::to_string_pretty(self)
            .map_err(|e| format!("序列化配置失败: {}", e))?;
        fs::write(&path, text)
            .map_err(|e| format!("写入配置失败: {}", e))?;
        Ok(())
    }
}

impl Account {
    fn from_cookie_string(cookie: &str) -> Option<Self> {
        let mut account = Self::default();
        for pair in cookie.split(';') {
            let pair = pair.trim();
            if let Some(v) = pair.strip_prefix("DedeUserID=") {
                account.dede_user_id = v.to_string();
            } else if let Some(v) = pair.strip_prefix("DedeUserID__ckMd5=") {
                account.dede_user_id_ckmd5 = v.to_string();
            } else if let Some(v) = pair.strip_prefix("SESSDATA=") {
                account.sessdata = v.to_string();
            } else if let Some(v) = pair.strip_prefix("bili_jct=") {
                account.bili_jct = v.to_string();
            } else if let Some(v) = pair.strip_prefix("buvid3=") {
                account.buvid3 = v.to_string();
            }
        }

        (!account.sessdata.is_empty() && !account.bili_jct.is_empty()).then_some(account)
    }

    fn from_config(config: &Config) -> Option<Self> {
        let account = Self {
            dede_user_id: config.dede_user_id.clone(),
            dede_user_id_ckmd5: config.dede_user_id_ckmd5.clone(),
            sessdata: config.sessdata.clone(),
            bili_jct: config.bili_jct.clone(),
            buvid3: config.buvid3.clone(),
        };
        (!account.sessdata.is_empty() && !account.bili_jct.is_empty()).then_some(account)
    }

    fn to_cookie_string(&self) -> String {
        let mut parts = Vec::new();
        if !self.sessdata.is_empty() { parts.push(format!("SESSDATA={}", self.sessdata)); }
        if !self.bili_jct.is_empty() { parts.push(format!("bili_jct={}", self.bili_jct)); }
        if !self.dede_user_id.is_empty() { parts.push(format!("DedeUserID={}", self.dede_user_id)); }
        if !self.dede_user_id_ckmd5.is_empty() {
            parts.push(format!("DedeUserID__ckMd5={}", self.dede_user_id_ckmd5));
        }
        if !self.buvid3.is_empty() { parts.push(format!("buvid3={}", self.buvid3)); }
        parts.join("; ")
    }

    fn apply_to_config(&self, config: &mut Config) {
        config.dede_user_id = self.dede_user_id.clone();
        config.dede_user_id_ckmd5 = self.dede_user_id_ckmd5.clone();
        config.sessdata = self.sessdata.clone();
        config.bili_jct = self.bili_jct.clone();
        config.buvid3 = self.buvid3.clone();
    }
}

pub fn get_storage_dir() -> PathBuf {
    let dir = dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("MutsuRelay");
    let _ = fs::create_dir_all(&dir);
    dir
}

pub fn init_from_config(config: &Config) {
    if let Some(account) = Account::from_config(config) {
        let cookie = account.to_cookie_string();
        if let Ok(mut c) = COOKIE_TEXT.lock() {
            *c = cookie;
        }
        COOKIE_VALID.store(true, Ordering::SeqCst);
        let info = UserInfo {
            mid: account.dede_user_id.parse().unwrap_or(0),
            uname: "B站用户".to_string(),
            is_login: true,
        };
        if let Ok(mut user) = USER_INFO.lock() {
            *user = Some(info);
        }
    }
    if config.roomid > 0 {
        set_room_id(config.roomid);
    }
    set_language(&config.language);
    set_close_behavior(&config.close_behavior);
}

pub fn generate_qrcode() -> String {
    let result = runtime()
        .and_then(|rt| rt.block_on(async {
            let response: serde_json::Value = reqwest::Client::new()
                .get("https://passport.bilibili.com/x/passport-login/web/qrcode/generate")
                .send()
                .await
                .map_err(|e| format!("获取二维码失败: {e}"))?
                .json()
                .await
                .map_err(|e| format!("解析二维码失败: {e}"))?;

            if response["code"].as_i64().unwrap_or(-1) != 0 {
                return Err(response["message"].as_str().unwrap_or("获取二维码失败").to_string());
            }

            Ok(serde_json::json!({
                "url": response["data"]["url"].as_str().unwrap_or_default(),
                "key": response["data"]["qrcode_key"].as_str().unwrap_or_default(),
            }).to_string())
        }));

    result.unwrap_or_else(|message| serde_json::json!({
        "url": "",
        "key": "",
        "error": message,
    }).to_string())
}

pub fn check_qrcode_status(key: &str) -> String {
    let key = key.to_string();
    let result = runtime()
        .and_then(|rt| rt.block_on(async move {
            let url = format!(
                "https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key={}",
                key
            );
            let response = reqwest::Client::new()
                .get(&url)
                .send()
                .await
                .map_err(|e| format!("检查扫码状态失败: {e}"))?;
            let cookie = collect_set_cookie(&response);
            let body: serde_json::Value = response
                .json()
                .await
                .map_err(|e| format!("解析扫码状态失败: {e}"))?;
            let code = body["data"]["code"].as_i64().unwrap_or(body["code"].as_i64().unwrap_or(-1));
            let (status, message) = match code {
                0 => ("success", "登录成功"),
                86090 => ("confirming", "已扫码，请在手机上确认登录"),
                86101 => ("waiting", "请使用B站App扫码"),
                86038 => ("expired", "二维码已过期，请刷新"),
                _ => ("waiting", body["message"].as_str().unwrap_or("等待扫码")),
            };
            Ok(serde_json::json!({
                "status": status,
                "cookie": if status == "success" { Some(cookie) } else { None },
                "message": message,
            }).to_string())
        }));

    result.unwrap_or_else(|message| serde_json::json!({
        "status": "error",
        "message": message,
    }).to_string())
}

fn collect_set_cookie(response: &reqwest::Response) -> String {
    response
        .headers()
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .filter_map(|value| value.split(';').next())
        .collect::<Vec<_>>()
        .join("; ")
}

pub fn set_cookie(cookie_str: &str) -> i32 {
    let Some(account) = Account::from_cookie_string(cookie_str) else {
        set_last_error("Cookie 格式不正确，无法解析");
        return -1;
    };
    let cookie = account.to_cookie_string();
    if let Ok(mut c) = COOKIE_TEXT.lock() {
        *c = cookie.clone();
    }
    COOKIE_VALID.store(true, Ordering::SeqCst);
    let mut config = Config::load().unwrap_or_default();
    account.apply_to_config(&mut config);
    let _ = config.save();
    clear_last_error();
    if let Err(e) = refresh_user_info() {
        log::error!("refresh_user_info failed: {e}");
        set_last_error(format!("获取用户信息失败: {e}"));
    }
    log::info!("Cookie set (length: {})", cookie.len());
    0
}

pub fn get_cookie_status() -> bool {
    COOKIE_VALID.load(Ordering::SeqCst)
}

pub fn get_account_info() -> UserInfo {
    // If placeholder name is cached, try to refresh from API
    {
        if let Ok(user) = USER_INFO.lock() {
            if let Some(ref info) = *user {
                if info.uname != "B站用户" || info.mid == 0 {
                    return info.clone();
                }
            }
        }
    }
    // Try fetching user info on demand if not cached or has placeholder
    if let Err(e) = refresh_user_info() {
        log::warn!("get_account_info: refresh failed: {e}");
    }
    if let Ok(user) = USER_INFO.lock() {
        if let Some(info) = user.clone() {
            return info;
        }
    }
    let cookie = current_cookie();
    let account = Account::from_cookie_string(&cookie).unwrap_or_default();
    UserInfo {
        mid: account.dede_user_id.parse::<u64>().unwrap_or(0),
        uname: if COOKIE_VALID.load(Ordering::SeqCst) { "B站用户" } else { "" }.to_string(),
        is_login: COOKIE_VALID.load(Ordering::SeqCst),
    }
}

pub fn refresh_user_info() -> Result<(), String> {
    let cookie = current_cookie();
    if cookie.is_empty() {
        return Err("未登录".to_string());
    }
    println!("[rust] refresh_user_info: calling Bilibili API");
    runtime()?.block_on(async {
        let client = reqwest::Client::builder()
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
            .build()
            .map_err(|e| format!("创建HTTP客户端失败: {e}"))?;
        let response = client
            .get("https://api.bilibili.com/x/web-interface/nav")
            .header(COOKIE, cookie)
            .send()
            .await
            .map_err(|e| {
                let msg = format!("获取用户信息失败: {e}");
                println!("[rust] refresh_user_info HTTP error: {msg}");
                msg
            })?;
        println!("[rust] refresh_user_info: got HTTP {}", response.status());
        let body: serde_json::Value = response.json().await.map_err(|e| {
            let msg = format!("解析用户信息失败: {e}");
            println!("[rust] refresh_user_info parse error: {msg}");
            msg
        })?;
        println!("[rust] refresh_user_info: body={}", body);

        if body["code"].as_i64().unwrap_or(-1) != 0 {
            let msg = body["message"].as_str().unwrap_or("登录已失效").to_string();
            println!("[rust] refresh_user_info API error: code={}, message={msg}", body["code"]);
            COOKIE_VALID.store(false, Ordering::SeqCst);
            return Err(msg);
        }

        let data = &body["data"];
        let info = UserInfo {
            mid: data["mid"].as_u64().unwrap_or(0),
            uname: data["uname"].as_str().unwrap_or("B站用户").to_string(),
            is_login: data["isLogin"].as_bool().unwrap_or(true),
        };
        println!("[rust] refresh_user_info: got name '{}', mid {}", info.uname, info.mid);
        COOKIE_VALID.store(info.is_login, Ordering::SeqCst);
        if let Ok(mut user) = USER_INFO.lock() {
            *user = Some(info);
        }
        Ok(())
    })
}

pub fn logout() {
    if let Ok(mut c) = COOKIE_TEXT.lock() {
        c.clear();
    }
    if let Ok(mut user) = USER_INFO.lock() {
        *user = None;
    }
    COOKIE_VALID.store(false, Ordering::SeqCst);
    let mut config = Config::load().unwrap_or_default();
    config.sessdata.clear();
    config.bili_jct.clear();
    config.dede_user_id.clear();
    config.dede_user_id_ckmd5.clear();
    config.buvid3.clear();
    let _ = config.save();
    log::info!("Logged out");
}

pub fn set_room_id(room_id: u64) {
    if let Ok(mut r) = ROOM_ID.lock() {
        *r = room_id;
    }
}

pub fn connect_room(room_id: u64) -> i32 {
    if room_id == 0 {
        set_last_error("房间号无效");
        return -1;
    }
    let url = format!("https://api.live.bilibili.com/room/v1/Room/room_init?id={}", room_id);
    let ok = runtime()
        .and_then(|rt| rt.block_on(async {
            let response: serde_json::Value = reqwest::Client::new()
                .get(&url)
                .send()
                .await
                .map_err(|e| format!("连接直播间失败: {e}"))?
                .json()
                .await
                .map_err(|e| format!("解析直播间失败: {e}"))?;
            if response["code"].as_i64().unwrap_or(-1) == 0 {
                Ok(response["data"]["room_id"].as_u64().unwrap_or(room_id))
            } else {
                Err(response["message"].as_str().unwrap_or("连接直播间失败").to_string())
            }
        }));

    match ok {
        Ok(real_room_id) => {
            set_room_id(real_room_id);
            let mut config = Config::load().unwrap_or_default();
            config.roomid = real_room_id;
            let _ = config.save();
            CONNECTED.store(true, Ordering::SeqCst);
            clear_last_error();
            log::info!("Connected to room: {}", real_room_id);
            0
        }
        Err(e) => {
            log::error!("{}", e);
            set_last_error(e);
            -1
        }
    }
}

pub fn get_room_id() -> u64 {
    ROOM_ID.lock().map(|r| *r).unwrap_or(0)
}

pub fn get_my_room_id() -> i64 {
    let cookie = current_cookie();
    let account = Account::from_cookie_string(&cookie).unwrap_or_default();
    let mid = account.dede_user_id.parse::<u64>().unwrap_or(0);
    if mid == 0 {
        set_last_error("无法从 Cookie 解析 UID");
        return -1;
    }

    let result = runtime()
        .and_then(|rt| rt.block_on(async move {
            let url = format!("https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld?mid={}", mid);
            let response: serde_json::Value = reqwest::Client::new()
                .get(&url)
                .header(COOKIE, current_cookie())
                .send()
                .await
                .map_err(|e| format!("获取直播间失败: {e}"))?
                .json()
                .await
                .map_err(|e| format!("解析直播间失败: {e}"))?;
            if response["code"].as_i64().unwrap_or(-1) == 0 {
                Ok(response["data"]["roomid"].as_u64().unwrap_or(0))
            } else {
                Err(response["message"].as_str().unwrap_or("无直播间").to_string())
            }
        }));

    match result {
        Ok(room_id) if room_id > 0 => {
            set_room_id(room_id);
            let mut config = Config::load().unwrap_or_default();
            config.roomid = room_id;
            let _ = config.save();
            room_id as i64
        }
        Err(e) => {
            set_last_error(e);
            -1
        }
        _ => {
            set_last_error("未找到账号对应的直播间");
            -1
        }
    }
}

pub fn set_language(lang: &str) {
    if let Ok(mut l) = LANGUAGE.lock() {
        *l = lang.to_string();
    }
}

pub fn get_language() -> String {
    LANGUAGE.lock().map(|l| l.clone()).unwrap_or_default()
}

pub fn set_close_behavior(behavior: &str) {
    if let Ok(mut b) = CLOSE_BEHAVIOR.lock() {
        *b = if behavior == "exit" { "exit" } else { "hide" }.to_string();
    }
}

pub fn get_close_behavior() -> String {
    CLOSE_BEHAVIOR.lock().map(|b| b.clone()).unwrap_or_default()
}

pub fn disconnect_room() {
    CONNECTED.store(false, Ordering::SeqCst);
    log::info!("Disconnected from room");
}

pub fn is_connected() -> bool {
    CONNECTED.load(Ordering::SeqCst)
}

pub fn send_message(text: &str) -> i32 {
    let msg = text.trim();
    let room_id = get_room_id();
    let cookie = current_cookie();
    let account = Account::from_cookie_string(&cookie).unwrap_or_default();
    if msg.is_empty() || room_id == 0 || account.bili_jct.is_empty() {
        set_last_error("请先登录并连接直播间");
        return -1;
    }

    let result = runtime()
        .and_then(|rt| rt.block_on(async move {
            let rnd = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs()
                .to_string();
            let params = [
                ("bubble", "0".to_string()),
                ("msg", msg.to_string()),
                ("color", "16777215".to_string()),
                ("mode", "1".to_string()),
                ("fontsize", "25".to_string()),
                ("rnd", rnd),
                ("roomid", room_id.to_string()),
                ("csrf", account.bili_jct.clone()),
                ("csrf_token", account.bili_jct),
            ];
            let response: serde_json::Value = reqwest::Client::new()
                .post("https://api.live.bilibili.com/msg/send")
                .header(COOKIE, cookie)
                .form(&params)
                .send()
                .await
                .map_err(|e| format!("发送失败: {e}"))?
                .json()
                .await
                .map_err(|e| format!("解析发送结果失败: {e}"))?;
            if response["code"].as_i64().unwrap_or(-1) == 0 {
                clear_last_error();
                Ok(())
            } else {
                Err(response["message"].as_str().unwrap_or("发送失败").to_string())
            }
        }));

    match result {
        Ok(()) => 0,
        Err(e) => {
            log::error!("{}", e);
            set_last_error(e);
            -1
        }
    }
}

fn current_cookie() -> String {
    COOKIE_TEXT.lock().map(|c| c.clone()).unwrap_or_default()
}
