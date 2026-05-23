# MutsuRelay

将麦克风语音实时转为文字，并通过 Bilibili 弹幕接口发送到直播间。当前工程是 Flutter 桌面界面 + Rust FFI 原生库版本，继承自原 Tauri/Rust/Vue 实现。

> 主要面向 Windows 桌面使用；Linux runner 已保留，但 ASR 运行库与桌面透明效果仍取决于本机环境。

## 功能

- 语音识别：Rust 原生库接入 sherpa-onnx / SenseVoice，支持离线 ASR
- 弹幕发送：扫码登录 Bilibili 后连接直播间，支持手动或自动发送
- 实时显示：录音过程中显示中间结果，结束后加入弹幕列表
- 小窗模式：窗口置顶，可通过滑块调节整体透明度
- OBS 捕捉：识别结果写入 `capture.txt`，可供 OBS 文本源读取
- 脏话过滤：支持关闭、替换为 `[***]`、替换为拼音首字母
- 噪声控制：提供噪声门限与降噪开关，降低环境噪音影响
- 托盘驻留：关闭窗口可隐藏到托盘，也可设置为直接退出

## 技术栈

| 层 | 技术 |
|---|---|
| 桌面界面 | Flutter |
| 状态管理 | provider |
| 窗口/托盘 | window_manager、tray_manager |
| 原生能力 | Rust 2021 cdylib/staticlib |
| FFI | Dart ffi |
| 麦克风 | cpal |
| 语音识别 | sherpa-onnx + SenseVoice |
| B站 API | reqwest |

## 项目结构

```text
mutsurelay_flutter/
├── lib/                  # Flutter 界面与 FFI 调用
│   ├── ffi/              # native_bridge.dart
│   ├── providers/        # AppState
│   ├── screens/          # 主界面 / 小窗界面
│   └── widgets/          # 控件
├── native/               # Rust 原生库：ASR、录音、B站、过滤
├── windows/              # Flutter Windows runner
├── linux/                # Flutter Linux runner
├── asr/                  # 本地 ASR 模型与运行库，需自行放置
└── pubspec.yaml
```

## 构建与运行

### 前置要求

- Flutter SDK
- Rust 工具链
- Windows：Visual Studio 2022 Build Tools / Windows SDK
- ASR 模型文件与 sherpa-onnx 运行库

### 准备 ASR 文件

将 SenseVoice 模型放到 `asr/model/`：

- `model.int8.onnx`
- `tokens.txt`

将 sherpa-onnx 运行时库放到 `asr/dll/`，或放到系统可搜索的动态库路径中。模型与 DLL 体积较大，默认不提交到 git。

### 构建原生库

Windows 可使用：

```powershell
cd native
.\build.ps1
```

脚本会构建 `mutsurelay_native.dll`，并复制到 Flutter Windows runner 可加载的位置。

也可以手动构建：

```bash
cd native
cargo build --release
```

### 启动 Flutter

```bash
flutter pub get
flutter run -d windows
```

Linux 调试时将目标改为：

```bash
flutter run -d linux
```

## 使用

1. 点击设置并使用 Bilibili App 扫码登录。
2. 输入或确认直播间号，点击连接直播间。
3. 点击麦克风开始录音，说完后识别结果会进入弹幕列表。
4. 手动模式下点击列表项发送；自动模式下识别结果会自动发送。
5. 点击顶栏的小窗按钮切换置顶小窗，并用透明度滑块调节窗口透明度。

## 配置与数据

配置目录由系统应用数据目录决定，应用名为 `MutsuRelay`。其中包含：

| 文件 | 说明 |
|---|---|
| `config.toml` | 房间号、关闭行为、过滤模式、VAD / ASR 配置 |
| `capture.txt` | OBS 文本源可读取的识别结果 |
| `blocklist.txt` | 自定义过滤词表 |

OBS 集成方式：添加文本源，启用从文件读取，选择配置目录中的 `capture.txt`。

## 常见问题

**Q: 语音识别不出文字？**

A: 检查模型与动态库是否放置正确，确认麦克风权限可用，并尝试调低噪声门限。

**Q: 发送失败？**

A: 先确认扫码登录有效、直播间已连接，再检查网络与 Bilibili 账号状态。

## 许可

Apache-2.0
