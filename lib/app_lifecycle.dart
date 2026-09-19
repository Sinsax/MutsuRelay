import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'ffi/native_bridge.dart';

/// 关闭窗口 / 退出应用（窗口关闭按钮、托盘菜单"退出"、`onWindowClose` 共用）。
///
/// **先让窗口从屏幕上消失，再做清理。**
/// `windowManager.destroy()` 在 Windows 上只是 `PostQuitMessage`
/// （见 window_manager 的 `WindowManager::Destroy`）——它**不销毁窗口**。窗口要等整个
/// 进程收尾走完才会被销毁：消息循环退出 → Flutter engine 关闭并 join 各渲染线程 →
/// 各插件 DLL detach → 还有约 300 MB 的 onnxruntime session 要回收。
/// 这段时间里窗口仍挂在屏幕上、但已经不再重绘，用户看到的就是
/// **"点了关闭，先卡住一下，然后才消失"**。
/// 先 `hide()` 就能把这段收尾时间从用户视野里彻底拿掉。
///
/// 顺序也是有意的：**先 hide，再动 native**。native 那边可能还有录音线程要收，
/// 万一某一步慢了，窗口也已经不在屏幕上了。
Future<void> quitApp() async {
  // 立刻消失（不留在任务栏里，避免收尾期间还能点到它）
  try {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  } catch (_) {}

  // 停录音 + 释放 native 侧资源。失败也必须继续往下走：退出流程不能因为
  // 一个异常就停在半路（那会变成"关不掉的窗口"）。
  try {
    NativeBridge.instance.shutdown();
  } catch (_) {}

  // 托盘图标必须在进程退出前删掉：否则通知区会留下一个"幽灵图标"，
  // 要等鼠标划过才消失。
  try {
    await trayManager.destroy();
  } catch (_) {}

  try {
    await windowManager.destroy();
  } catch (_) {}
}
