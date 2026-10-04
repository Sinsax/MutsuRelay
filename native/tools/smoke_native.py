#!/usr/bin/env python
"""native 库运行时冒烟测试（不依赖 Flutter 的回归手段）。

这是改完 native 后最快的端到端手段：用 ctypes 直接加载 mutsurelay_native.dll，
把 C API 全链路跑一遍，用来回答"改完还能不能用"：

  1. DLL 与全部运行库依赖能否加载
  2. Dart 绑定的每个符号是否都能解析
  3. init / poll / censor / 噪声门 / 语言 / 配置 的基本行为
  4. 录音链路真的能起停，音频真的流进来了（stats.captured_chunks > 0）
  5. 重建去重：调参不得触发 recognizer 重建风暴（见 [6c]）

（Flutter 侧另有 `flutter analyze` / `flutter test` 可用，本脚本不替代它们，
只覆盖 Dart 侧测不到的 native 运行时行为。）

用法：
    python native/tools/smoke_native.py                     # 自动找 target/debug
    python native/tools/smoke_native.py --dll <path>        # 指定 dll
    python native/tools/smoke_native.py --no-record         # 跳过录音段（无麦克风环境）
    python native/tools/smoke_native.py --seconds 5         # 录音时长

退出码 0 = 全部通过。
"""

import argparse
import ctypes
import json
import os
import re
import struct
import sys
import time
from ctypes import POINTER, c_char_p, c_double, c_int, c_int64, c_uint, c_void_p

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PASS, FAIL, WARN = [], [], []


def ok(name, detail=""):
    PASS.append(name)
    print(f"  [PASS] {name}" + (f"  ({detail})" if detail else ""))


def bad(name, detail=""):
    FAIL.append(name)
    print(f"  [FAIL] {name}" + (f"  ({detail})" if detail else ""))


def warn(name, detail=""):
    WARN.append(name)
    print(f"  [WARN] {name}" + (f"  ({detail})" if detail else ""))


# ---------------------------------------------------------------- DLL 加载


def peek_exports(path):
    """从 PE 导出表列出符号名（不加载 DLL，先做静态核对）。"""
    d = open(path, "rb").read()
    e = struct.unpack_from("<I", d, 0x3C)[0]
    if d[e : e + 4] != b"PE\x00\x00":
        raise ValueError("不是 PE 文件")
    nsec = struct.unpack_from("<H", d, e + 6)[0]
    optsz = struct.unpack_from("<H", d, e + 20)[0]
    opt = e + 24
    magic = struct.unpack_from("<H", d, opt)[0]
    ddir = opt + (112 if magic == 0x20B else 96)
    erva, _ = struct.unpack_from("<II", d, ddir)
    secs, so = [], opt + optsz
    for i in range(nsec):
        b = so + i * 40
        name = d[b : b + 8].rstrip(b"\x00").decode("ascii", "replace")
        vsz, vaddr, rsz, raddr = struct.unpack_from("<IIII", d, b + 8)
        secs.append((name, vaddr, vsz, raddr, rsz))

    def rva2off(rva):
        for _, va, vs, ra, rs in secs:
            if va <= rva < va + max(vs, rs):
                return ra + (rva - va)
        return None

    eo = rva2off(erva)
    if eo is None:
        return []
    nnames = struct.unpack_from("<I", d, eo + 24)[0]
    anames = struct.unpack_from("<I", d, eo + 32)[0]
    no = rva2off(anames)
    out = []
    for i in range(nnames):
        nr = struct.unpack_from("<I", d, no + i * 4)[0]
        o = rva2off(nr)
        if o is None:
            continue
        out.append(d[o : d.index(b"\x00", o)].decode("ascii", "replace"))
    return out


def dart_bound_symbols():
    """从 native_bridge.dart 抽出所有被绑定的 C 符号名。"""
    src = open(
        os.path.join(REPO, "lib", "ffi", "native_bridge.dart"), encoding="utf-8"
    ).read()
    return sorted(set(re.findall(r"'(mutsurelay_[a-z_0-9]+)'", src)))


def dart_expected_abi():
    """从 native_bridge.dart 抽出它期望的 ABI 版本号。"""
    src = open(
        os.path.join(REPO, "lib", "ffi", "native_bridge.dart"), encoding="utf-8"
    ).read()
    m = re.search(r"expectedAbiVersion\s*=\s*(\d+)", src)
    return int(m.group(1)) if m else None


def default_dll():
    for rel in (
        "native/target/debug/mutsurelay_native.dll",
        "native/target/release/mutsurelay_native.dll",
        "windows/mutsurelay_native/mutsurelay_native.dll",
    ):
        p = os.path.join(REPO, *rel.split("/"))
        if os.path.isfile(p):
            return p
    return None


def load(dll_path):
    # add_dll_directory 只接受绝对路径（相对路径会抛 WinError 87），而 ctypes 的
    # LoadLibrary 在 add_dll_directory 生效后也只能按绝对路径找依赖。
    dll_path = os.path.abspath(dll_path)
    d = os.path.dirname(dll_path)
    if hasattr(os, "add_dll_directory"):
        os.add_dll_directory(d)
    return ctypes.cdll.LoadLibrary(dll_path)


# ---------------------------------------------------------------- 主流程


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll", default=None)
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--no-record", action="store_true")
    args = ap.parse_args()

    dll = args.dll or default_dll()
    if not dll or not os.path.isfile(dll):
        print("找不到 mutsurelay_native.dll，先 cargo build")
        return 1

    print("=" * 68)
    print("native 运行时冒烟测试")
    print(f"  DLL : {dll}")
    print(f"  大小 : {os.path.getsize(dll) / 1048576:.1f} MB")
    print("=" * 68)

    # --- 1. 静态符号核对 ---
    print("\n[1] 导出符号 vs Dart 绑定")
    exports = peek_exports(dll)
    bound = dart_bound_symbols()
    missing = [b for b in bound if b not in exports]
    if missing:
        bad("Dart 绑定符号齐全", f"缺失 {missing}")
    else:
        ok("Dart 绑定符号齐全", f"{len(bound)} 个全部存在")

    # --- 2. 动态加载 ---
    print("\n[2] 加载 DLL 与运行库")
    try:
        lib = load(dll)
        ok("ctypes 加载成功")
    except OSError as e:
        bad("ctypes 加载成功", str(e))
        return 1

    def bind(name, restype, *argtypes):
        try:
            f = getattr(lib, name)
            f.restype = restype
            f.argtypes = list(argtypes)
            return f
        except AttributeError:
            bad(f"解析 {name}")
            return None

    init = bind("mutsurelay_init", c_int, c_char_p)
    init_asr = bind("mutsurelay_init_asr", c_int, c_char_p)
    shutdown = bind("mutsurelay_shutdown", None)
    start_rec = bind("mutsurelay_start_recording", c_int)
    stop_rec = bind("mutsurelay_stop_recording", None)
    is_rec = bind("mutsurelay_is_recording", c_int)
    poll = bind("mutsurelay_poll_recording", c_void_p)
    get_stats = bind("mutsurelay_get_stats", c_void_p)
    free_str = bind("mutsurelay_free_string", None, c_void_p)
    censor_text = bind("mutsurelay_censor_text", c_void_p, c_char_p)
    set_cmode = bind("mutsurelay_set_censor_mode", None, c_int)
    get_cmode = bind("mutsurelay_get_censor_mode", c_int)
    set_gate = bind("mutsurelay_set_noise_gate", None, c_double)
    get_gate = bind("mutsurelay_get_noise_gate", c_double)
    set_sup = bind("mutsurelay_set_noise_suppress", None, c_int)
    get_sup = bind("mutsurelay_get_noise_suppress", c_int)
    set_lang = bind("mutsurelay_set_asr_lang", None, c_char_p)
    get_lang = bind("mutsurelay_get_asr_lang", c_void_p)
    set_sub = bind("mutsurelay_set_subtitle_file_path", None, c_char_p)
    get_sub = bind("mutsurelay_get_subtitle_file_path", c_void_p)
    load_cfg = bind("mutsurelay_load_config", c_int)
    save_cfg = bind("mutsurelay_save_config", c_int)
    get_cfg_dir = bind("mutsurelay_get_config_dir_path", c_void_p)
    get_last_err = bind("mutsurelay_get_last_error", c_void_p)
    # P2/P3 新增
    reload_asr = bind("mutsurelay_reload_asr", c_int, c_char_p)
    set_seg_max = bind("mutsurelay_set_segment_max_ms", None, c_uint)
    get_seg_max = bind("mutsurelay_get_segment_max_ms", c_uint)
    set_interim = bind("mutsurelay_set_interim", None, c_int)
    get_interim = bind("mutsurelay_get_interim", c_int)
    enqueue_msg = bind("mutsurelay_enqueue_message", c_int64, c_char_p)
    poll_send = bind("mutsurelay_poll_send_results", c_void_p)
    asr_state = bind("mutsurelay_asr_state", c_int)
    if not all([init, start_rec, poll, get_stats, free_str]):
        return 1
    ok("关键函数指针解析")

    # ABI 版本必须两边一致，否则旧平台的 .so/.dll 会被静默当成 mock
    abi = bind("mutsurelay_abi_version", c_uint)
    want_abi = dart_expected_abi()
    if abi is None:
        bad("mutsurelay_abi_version 可解析")
    elif want_abi is None:
        warn("Dart 侧未声明 expectedAbiVersion")
    else:
        got_abi = abi()
        (ok if got_abi == want_abi else bad)(
            "ABI 版本两侧一致", f"dll={got_abi} dart={want_abi}"
        )

    def take(ptr):
        if not ptr:
            return None
        try:
            s = ctypes.cast(ptr, c_char_p).value.decode("utf-8", "replace")
        finally:
            free_str(ptr)
        return s

    def jpoll():
        raw = take(poll())
        return json.loads(raw) if raw else None

    def jstats():
        raw = take(get_stats())
        return json.loads(raw) if raw else None

    # --- 3. init ---
    print("\n[3] 初始化")
    model_dir = os.path.join(REPO, "asr", "model")
    r = init(model_dir.encode("utf-8"))
    if r == 0:
        ok("mutsurelay_init 返回 0")
    else:
        bad("mutsurelay_init 返回 0", f"got {r}")
    ok("配置目录", take(get_cfg_dir()))
    if init_asr:
        r = init_asr(model_dir.encode("utf-8"))
        (ok if r == 0 else bad)("mutsurelay_init_asr 返回 0", f"got {r}")

    # 启动路径**不得**把模型装进内存：常驻 recognizer 约 300 MB（模型文件 228 MB →
    # 加载后 RSS +298 MB），而应用刚打开时多数时间并没有在录音。
    # 加载推迟到"首次开始录音"，见 [6d]。
    if asr_state:
        st0 = asr_state()
        if st0 == 0:
            ok("启动路径不预加载模型（懒加载）", "state=0，未录音时不占 ~300 MB")
        else:
            bad("启动路径不预加载模型（懒加载）", f"state={st0}（期望 0 = IDLE）")

    # --- 4. 基线 poll ---
    print("\n[4] 基线状态")
    p = jpoll()
    if p is None:
        bad("poll_recording 返回合法 JSON")
    else:
        ok("poll_recording 返回合法 JSON", f"keys={sorted(p.keys())}")
        for k in ("recording", "level", "in_speech", "error", "results", "stats"):
            if k not in p:
                bad(f"poll 含字段 {k}")
        if p.get("recording") is False:
            ok("未录音时 recording=false")
        else:
            bad("未录音时 recording=false", str(p.get("recording")))
        if isinstance(p.get("results"), list):
            ok("results 是数组（队列语义）")
        st = jstats()
        if st:
            # P2 起字段换过一轮：丢样按样本计、段队列深度/延迟直方图都进了 stats
            need = {
                "captured_chunks", "dropped_samples", "dropped_segments",
                "rejected_segments", "rejected_text", "seam_trimmed",
                "decoded", "results", "dropped_results",
                "interim_runs", "interim_results", "asr_state", "sessions",
                "asr_reloads", "asr_reload_skipped",
                "queue_depth", "seg_queue_depth", "seg_queue_max",
                "decode_avg_ms", "decode_p50_ms", "decode_p95_ms", "decode_max_ms",
                "frontend_avg_ms", "frontend_p95_ms", "frontend_max_ms",
                "frontend_iters",
            }
            miss = need - set(st.keys())
            (ok if not miss else bad)("get_stats 字段齐全", f"缺 {miss}" if miss else f"{len(st)} 项")
        else:
            bad("mutsurelay_get_stats 返回合法 JSON")

    # --- 5. censor ---
    print("\n[5] 敏感词")
    for mode, expect_callable in ((1, lambda s: "[***]" in s), (2, lambda s: s != "你这个废物")):
        set_cmode(mode)
        if get_cmode() != mode:
            bad(f"censor mode {mode} 往返")
        out = take(censor_text("你这个废物".encode("utf-8")))
        if out is None:
            bad(f"censor mode {mode} 有输出")
        elif mode == 1 and not expect_callable(out):
            bad("mode 1 掩码为 [***]", repr(out))
        else:
            ok(f"censor mode {mode}", repr(out))
    set_cmode(0)
    out = take(censor_text("你这个废物".encode("utf-8")))
    (ok if out == "你这个废物" else bad)("mode 0 原文直通", repr(out))

    # --- 6. 噪声门 / 语言 / 字幕路径 往返 ---
    print("\n[6] 设置项往返")
    set_gate(0.037)
    g = get_gate()
    (ok if abs(g - 0.037) < 1e-6 else bad)("noise_gate 往返", f"{g}")
    set_gate(0.02)
    set_sup(1)
    (ok if get_sup() == 1 else bad)("noise_suppress 往返 (on)")
    set_sup(0)
    (ok if get_sup() == 0 else bad)("noise_suppress 往返 (off)")
    set_sup(1)
    set_lang(b"zh")
    (ok if take(get_lang()) == "zh" else bad)("asr_lang 往返", repr(take(get_lang())))
    set_sub(b"C:/tmp/_smoke_sub.txt")
    (ok if take(get_sub()) == "C:/tmp/_smoke_sub.txt" else bad)("subtitle_file_path 往返")

    # --- 6b. P2/P3 新接口 ---
    print("\n[6b] P2/P3 接口")
    if set_seg_max and get_seg_max:
        set_seg_max(6500)
        (ok if get_seg_max() == 6500 else bad)("segment_max_ms 往返", f"{get_seg_max()}")
        set_seg_max(50)  # 低于下限应被 clamp
        (ok if get_seg_max() >= 1000 else bad)("segment_max_ms 下限 clamp", f"{get_seg_max()}")
        set_seg_max(999999)
        (ok if get_seg_max() <= 30000 else bad)("segment_max_ms 上限 clamp", f"{get_seg_max()}")
        set_seg_max(8000)
    if set_interim and get_interim:
        set_interim(0)
        (ok if get_interim() == 0 else bad)("interim 往返 (off)")
        set_interim(1)
        (ok if get_interim() == 1 else bad)("interim 往返 (on)")
    if poll_send:
        raw = take(poll_send())
        try:
            arr = json.loads(raw) if raw else None
        except Exception:
            arr = None
        (ok if isinstance(arr, list) else bad)("poll_send_results 返回 JSON 数组", repr(raw)[:50])
    if enqueue_msg:
        # 未连接直播间时必须**立即失败**且不产生任务
        job = enqueue_msg("__smoke_never_sent__".encode("utf-8"))
        if job <= 0:
            ok("未连接时 enqueue_message 立即失败", f"job={job}")
            err = take(get_last_err()) or ""
            (ok if err else warn)("立即失败带上原因", err[:60] if err else "last_error 为空")
        else:
            warn("未连接时 enqueue_message 竟然受理了", f"job={job}")
        job = enqueue_msg(b"")
        (ok if job <= 0 else bad)("空消息被拒绝", f"job={job}")
    if reload_asr:
        r = reload_asr(model_dir.encode("utf-8"))
        (ok if r == 0 else bad)("reload_asr 返回 0", f"got {r}")
    if asr_state:
        # reload 在后台线程做，等它就绪（模型 240 MB，给足时间）
        deadline = time.time() + 60
        st_val = asr_state()
        while time.time() < deadline and st_val == 0:
            time.sleep(0.25)
            st_val = asr_state()
        if st_val == 1:
            ok("asr_state 变为就绪(1)")
        elif st_val == -1:
            warn("asr_state = 加载失败", "模型文件缺失？")
        else:
            bad("asr_state 未在 60s 内就绪", f"state={st_val}")

    # --- 6c. 重建去重：调参不得触发 recognizer 重建风暴 ---
    #
    # 真机反馈：只拖了一下灵敏度滑块，CPU 就 10%+，日志里 10 s 内出现 8 次
    # "ASR reloaded (1412..1487ms)"，之后说话又慢又不出字。
    # 链路是：滑块 onChanged → 保存设置 → set_asr_lang → 无条件重建 recognizer。
    # 一次重建 = 229 MB 模型重新加载约 1.4 s，期间解码线程完全停摆、
    # 段队列按容量丢最旧。这里把这条链路钉成回归测试。
    print("\n[6c] 重建去重（灵敏度拖动回归）")
    if set_lang and asr_state:

        def wait_ready(timeout=60.0):
            dl = time.time() + timeout
            while time.time() < dl and asr_state() == 0:
                time.sleep(0.25)
            return asr_state()

        # 让内存与配置文件一致：后面那些"同值设置"才是真正的 no-op
        lang_now = take(get_lang()) or "zh"
        set_lang(lang_now.encode("utf-8"))
        if save_cfg:
            save_cfg()
        wait_ready()
        base = jstats() or {}
        r0 = base.get("asr_reloads", 0)
        s0 = base.get("asr_reload_skipped", 0)

        # A) 语言没变：连调 30 次（拖动滑块的真实形状）不得触发任何重建
        for i in range(30):
            set_gate(0.001 * (1 + i % 50))
            set_lang(lang_now.encode("utf-8"))
        time.sleep(0.8)
        dr = (jstats() or {}).get("asr_reloads", 0) - r0
        if dr == 0:
            ok("语言未变时 30 次设置不触发重建", "reloads +0")
        else:
            bad("语言未变时 30 次设置不触发重建", f"reloads +{dr}（期望 0）")

        # B) 目标已经装好：应用启动时 init_asr 之后紧接着 loadSettings→load_config
        #    会再请求一次**完全相同**的目标，不该把 229 MB 模型装第二遍
        init_asr(model_dir.encode("utf-8"))
        load_cfg()
        time.sleep(0.8)
        dr = (jstats() or {}).get("asr_reloads", 0) - r0
        if dr == 0:
            ok("已装载的同目标请求被短路", "init_asr + load_config 未重复加载")
        else:
            bad("已装载的同目标请求被短路", f"reloads +{dr}（期望 0）")

        # C) 语言真的变了：只应重建一次
        set_gate(0.02)
        other = "en" if lang_now != "en" else "zh"
        set_lang(other.encode("utf-8"))
        for _ in range(10):
            set_lang(other.encode("utf-8"))
        time.sleep(2.5)
        st2 = jstats() or {}
        dr = st2.get("asr_reloads", 0) - r0
        ds = st2.get("asr_reload_skipped", 0) - s0
        if dr == 1:
            ok("换语言只重建一次", f"reloads +{dr} skipped +{ds}")
        else:
            bad("换语言只重建一次", f"reloads +{dr}（期望 1）")

        # 还原成配置里的语言，避免影响后面的录音段
        set_lang(lang_now.encode("utf-8"))
        if save_cfg:
            save_cfg()
        (ok if wait_ready() == 1 else bad)("还原语言后 ASR 就绪", f"state={asr_state()}")

    # --- 6d. 懒加载 / 空闲卸载 ---
    # 真机反馈："内存占用 500 MB"。其中约 300 MB 是常驻的 recognizer
    # （模型文件 228 MB → 加载后 RSS +298 MB）。旧实现在启动路径
    # （init_asr / load_config / set_asr_lang）里就把模型装进内存，而多数时间
    # 根本没在录音。现在改成**首次开始录音时才加载**，停止录音 60 s 后自动卸载。
    # 这里把两条都钉成回归。
    print("\n[6d] 懒加载与空闲卸载")
    if reload_asr and asr_state and start_rec and stop_rec:
        # 1) 传空模型目录 = 主动卸载（与"空闲 60 s 自动卸载"是同一条代码路径）
        #
        # 注意：`request_reload` 会在**调用方线程**先把 LOAD_STATE 置成 IDLE 再入队
        # （那是为了避免 UI 读到陈旧的 READY），所以"等 asr_state 变成 0"会和解码
        # 线程赛跑 —— 必须等 `asr_reloads` 真的增长，才说明卸载已经落地。
        r0 = (jstats() or {}).get("asr_reloads", 0)
        reload_asr(b"")
        dl = time.time() + 30
        while time.time() < dl and (jstats() or {}).get("asr_reloads", 0) == r0:
            time.sleep(0.2)
        r1 = (jstats() or {}).get("asr_reloads", 0)
        if r1 > r0:
            ok("卸载请求已被解码线程处理", f"reloads +{r1 - r0}")
        else:
            bad("卸载请求已被解码线程处理", "30 s 内未处理")
        st_val = asr_state()
        if st_val == 0:
            ok("卸载后状态回到 IDLE(0)", "空模型目录 = 主动卸载，不是加载失败")
        elif st_val == -1:
            bad(
                "卸载后状态回到 IDLE(0)",
                "被记成 FAILED(-1)：界面会误报“ASR 加载失败”",
            )
        else:
            bad("卸载后状态回到 IDLE(0)", f"state={st_val}（仍显示就绪？）")

        # 2) 启动路径只同步目标，不得把模型拉回内存
        init_asr(model_dir.encode("utf-8"))
        load_cfg()
        if save_cfg:
            save_cfg()
        time.sleep(1.0)
        if asr_state() == 0:
            ok("启动路径不预加载模型", "init_asr + load_config 后仍未就绪")
        else:
            bad("启动路径不预加载模型", f"state={asr_state()}（期望 0）")
        dr = (jstats() or {}).get("asr_reloads", 0) - r1
        if dr == 0:
            ok("未录音时的同目标空转不触发重建", f"reloads +{dr}")
        else:
            bad("未录音时的同目标空转不触发重建", f"reloads +{dr}（期望 0）")

        # 3) 开始录音必须自己把模型装回来 —— 这是懒加载真正的入口
        r2 = (jstats() or {}).get("asr_reloads", 0)
        start_rec()
        dl = time.time() + 60
        while time.time() < dl and asr_state() == 0:
            time.sleep(0.25)
        if asr_state() == 1:
            ok("开始录音时自动加载模型", "懒加载入口生效")
        else:
            bad("开始录音时自动加载模型", f"state={asr_state()}（期望 1）")
        dr = (jstats() or {}).get("asr_reloads", 0) - r2
        if dr == 1:
            ok("自动加载只重建一次", f"reloads +{dr}")
        else:
            bad("自动加载只重建一次", f"reloads +{dr}（期望 1）")
        stop_rec()
        time.sleep(0.5)

    # --- 7. 配置读取 ---
    print("\n[7] 配置持久化")
    r = load_cfg()
    (ok if r == 0 else warn)("load_config", f"返回 {r}")
    le = take(get_last_err())
    ok("get_last_error 可调用", repr(le)[:60])

    # 段长上限 / interim 的往返（本轮新增的两项配置）。
    # 先读原值，写测试值 → save → load → 断言，最后把原值写回去，
    # 避免 smoke 测试顺手改掉用户真实 config.toml 里的设置。
    orig_ms, orig_interim = get_seg_max(), get_interim()
    if 1000 <= orig_ms <= 30000:
        ok("段长上限在合法区间", f"{orig_ms}ms")
    else:
        bad("段长上限在合法区间", f"{orig_ms}ms")
    set_seg_max(6000)
    set_interim(0)
    r_save = save_cfg()
    (ok if r_save == 0 else bad)("save_config 返回 0", f"got {r_save}")
    load_cfg()
    if get_seg_max() == 6000 and get_interim() == 0:
        ok("段长/interim 往返一致", "6000ms / off")
    else:
        bad("段长/interim 往返不一致", f"{get_seg_max()}ms / {get_interim()}")
    set_seg_max(orig_ms)
    set_interim(orig_interim)
    save_cfg()
    if get_seg_max() == orig_ms and get_interim() == orig_interim:
        ok("已还原原设置", f"{orig_ms}ms / {'on' if orig_interim else 'off'}")
    else:
        warn("还原原设置", f"{get_seg_max()}ms / {get_interim()}（原 {orig_ms}ms）")

    # --- 8. 录音链路 ---
    print("\n[8] 录音链路")
    if args.no_record:
        warn("录音测试", "已跳过 (--no-record)")
    else:
        if is_rec() != 0:
            bad("开始前 is_recording=0")
            stop_rec()
            time.sleep(0.5)
        r = start_rec()
        (ok if r == 0 else bad)("start_recording 返回 0", f"got {r}")
        time.sleep(0.4)
        if is_rec() != 0:
            ok("start 后 is_recording=1")
        else:
            bad("start 后 is_recording=1", "线程已退出（可能无麦克风）")

        deadline = time.time() + args.seconds
        levels, errs, results = [], [], []
        while time.time() < deadline:
            p = jpoll()
            if p:
                levels.append(p.get("level", 0.0))
                if p.get("error"):
                    errs.append(p["error"])
                results.extend(p.get("results") or [])
            time.sleep(0.1)
        peak = max(levels) if levels else 0.0
        st = jstats() or {}
        print(f"       采样 {len(levels)} 次 | 电平峰值 {peak:.4f} | "
              f"captured_chunks={st.get('captured_chunks')} dropped={st.get('dropped_samples')}")

        if errs:
            warn("录音期间有错误上报（预期行为，非崩溃）", errs[0][:80])
        if st.get("captured_chunks", 0) > 0:
            ok("音频真的流进来了", f"captured_chunks={st['captured_chunks']}")
            if peak > 0:
                ok("电平表有非零输出", f"peak={peak:.4f}")
            else:
                warn("电平表全程为 0", "环境静音或电平映射需复核")
        else:
            warn("未捕获到音频块", "无麦克风 / 被占用 / 设备不支持")
            if errs:
                ok("失败有明确报错", errs[0][:80])
            else:
                bad("失败无报错（应写 PIPELINE_ERROR）")

        stop_rec()
        time.sleep(1.0)
        p = jpoll()
        if p and p.get("recording") is False:
            ok("stop 后 recording=false")
        else:
            bad("stop 后 recording=false", str(p and p.get("recording")))

    # --- 9. 重复起停（并发 pipeline 回归） ---
    if not args.no_record:
        print("\n[9] 重复起停 x3（并发 pipeline 回归）")
        # 只断言"最终回到停止态"是不够的：真正的回归风险是**第二轮起不来**
        # （旧 stream 还没 drop 就开新 stream → 设备被占用 → fail_session）。
        # 那种情况下 is_recording 也会回到 0，测试照样"通过"。所以每轮都要
        # 确认 captured_chunks 真的在涨。
        prev = (jstats() or {}).get("captured_chunks", 0)
        resumed = 0
        for i in range(3):
            r = start_rec()
            if r != 0:
                bad(f"第 {i + 1} 轮 start_recording 返回 0", f"got {r}")
            time.sleep(0.5)
            cur = (jstats() or {}).get("captured_chunks", 0)
            if cur > prev:
                resumed += 1
            else:
                bad(f"第 {i + 1} 轮起停后音频未流入", f"captured_chunks {prev} → {cur}")
            prev = cur
            stop_rec()
            time.sleep(0.1)
        if resumed == 3:
            ok("3 轮起停每轮都重新采到音频", f"累计 captured_chunks={prev}")

        # 极端时序：几乎不停顿地起停，检验并发 pipeline 不留残留
        for _ in range(3):
            start_rec()
            time.sleep(0.05)
            stop_rec()
            time.sleep(0.05)
        time.sleep(1.2)
        if is_rec() == 0:
            ok("急速起停后最终回到停止态")
        else:
            bad("急速起停后最终回到停止态", "仍有 pipeline 存活")
        st = jstats() or {}
        print(f"       captured_chunks 累计={st.get('captured_chunks')} "
              f"dropped={st.get('dropped_samples')} results={st.get('results')} "
              f"dropped_segments={st.get('dropped_segments')}")

    # --- 10. shutdown ---
    print("\n[10] 关闭")
    if shutdown:
        shutdown()
        ok("mutsurelay_shutdown 未崩溃")

    print("\n" + "=" * 68)
    print(f"PASS {len(PASS)}   FAIL {len(FAIL)}   WARN {len(WARN)}")
    if FAIL:
        print("失败项：")
        for f in FAIL:
            print("   -", f)
    print("=" * 68)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
