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
- 噪声控制：提供噪声门限（灵敏度可调）与降噪开关，降低环境噪音影响
- 托盘驻留：关闭窗口可隐藏到托盘，也可设置为直接退出
- 文件直达：设置中一键打开配置目录和字幕文件位置

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
mutsurelay/
├── lib/                    # Flutter 界面与 FFI 调用
│   ├── ffi/                # native_bridge.dart
│   ├── providers/          # AppState
│   ├── screens/            # 主界面 / 小窗界面
│   └── widgets/            # 控件
├── native/                 # Rust 原生库：ASR、录音、B站、过滤
├── windows/                # Flutter Windows runner (CMake)
│   └── installer/          # Inno Setup 安装脚本
├── linux/                  # Flutter Linux runner (CMake)
│   └── packaging/          # AppImage 打包配置
├── cmake/                  # 共享 CMake 模块（模型下载 + Rust 构建）
├── tool/                   # 开发工具脚本
├── asr/                    # ASR 模型（CMake 自动下载）
├── dist/                   # 打包产物输出目录（.exe / .zip / .AppImage）
└── pubspec.yaml            # 版本号唯一来源（1.0.0+1）
```

## 构建与运行

### 前置要求

- Flutter SDK
- Rust 工具链
- Windows：Visual Studio 2022 Build Tools / Windows SDK
- Linux：`clang libclang-dev libgtk-3-dev libasound2-dev liblz4-dev pkg-config`
- 打包（可选）：Inno Setup 6（`winget install JRSoftware.InnoSetup`）

版本号统一在 `pubspec.yaml` 中管理（`version: 1.0.0+1`），构建时自动写入 EXE 元数据和安装包文件名。

### 一键构建

CMake 会自动下载 ASR 模型（~200MB）+ 编译 Rust 原生库 + 打包所有文件：

```bash
flutter build windows --release   # Windows
flutter build linux --release     # Linux
```

无需手动准备模型或运行库。

### 快速迭代（跳过 CMake）

先构建 Rust 原生库，再启动 Flutter（二选一）：

**一步到位（推荐，跨平台）：**
```bash
dart run tool/build_and_run.dart
```

**分步执行：**
```powershell
# Windows
native\build.ps1                  # cargo build + 复制 DLL
flutter run -d windows

# Linux
bash native/build.sh
flutter run -d linux
```

### 一键打包（推荐）

全平台自动检测，一步完成构建+打包：

```bash
dart run tool/package.dart
```

Windows 产出 `dist/MutsuRelay-<version>.zip` + `dist/MutsuRelay-<version>-setup.exe`。
Linux 产出 `*.AppImage`。

### 分步打包

```powershell
# Windows Inno Setup 安装包（可选路径、开始菜单、卸载）
iscc windows\installer\setup.iss

# Windows 便携 ZIP（解压即用）
Compress-Archive -Path "build\windows\x64\runner\Release\*" -DestinationPath "dist\MutsuRelay.zip"

# Linux AppImage
dart run fastforge package --platform linux --targets appimage
```

CI 会在每次推送时自动执行完整构建+打包流程，产物可在 Action 页面下载。

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

OBS 集成方式：添加文本源，启用从文件读取，选择配置目录中的 `capture.txt`。也可以在设置中点击「字幕文件 → 打开文件」直达 `capture.txt` 位置。

## 常见问题

**Q: 语音识别不出文字？**

A: 检查模型与动态库是否放置正确，确认麦克风权限可用，并尝试调低噪声门限。

**Q: 发送失败？**

A: 先确认扫码登录有效、直播间已连接，再检查网络与 Bilibili 账号状态。

## 许可

Apache-2.0
