"""量 ASR 模型加载/卸载对进程 RSS 的影响，并检查反复重建是否会留下残留。

为什么需要它：模型文件 228 MB，onnxruntime 加载后往往远不止这个数，而"卸载到底还不还给
OS"决定了"空闲卸载"方案值不值得做。这里用 ctypes 直接把 DLL 加载进本进程量 WorkingSet。

用法：
    python native/tools/mem_probe.py                 # 默认量 1 轮加载 → 卸载
    python native/tools/mem_probe.py --cycles 3      # 连续 3 轮，看有没有累积残留
    python native/tools/mem_probe.py --dll <path>    # 指定 DLL（默认 native/target/debug）

注意（2026-10-05 修）：`mutsurelay_init_asr` 是**懒加载**的 —— 它只走
`trigger_reload_if_loaded()`，模型没装着时什么也不做。本脚本原先用 init_asr 触发加载，
于是量出来"模型增量 ≈ 0 MB"，纯属假数据。真正会加载的入口是
`mutsurelay_reload_asr`（界面的"重启 ASR"，forced）。
"""

import argparse
import ctypes
import glob
import os
import time
from ctypes import wintypes

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_DLLDIR = os.path.join(REPO, 'native', 'target', 'debug')
DEFAULT_DLL = os.path.join(DEFAULT_DLLDIR, 'mutsurelay_native.dll')
MODEL_DIR = os.path.join(REPO, 'asr', 'model')


class PMC(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]


_k32 = ctypes.windll.kernel32
_k32.GetCurrentProcess.restype = wintypes.HANDLE

_gpmi = None
for _mod, _name in ((ctypes.windll.kernel32, 'K32GetProcessMemoryInfo'),
                    (ctypes.windll.psapi, 'GetProcessMemoryInfo')):
    try:
        _fn = getattr(_mod, _name)
        _fn.argtypes = [wintypes.HANDLE, ctypes.POINTER(PMC), wintypes.DWORD]
        _fn.restype = wintypes.BOOL
        _gpmi = _fn
        break
    except AttributeError:
        continue
if _gpmi is None:
    print('!! 找不到 GetProcessMemoryInfo，内存数据不可用')


def _sample():
    c = PMC(); c.cb = ctypes.sizeof(c)
    if _gpmi is None:
        return -1.0, -1.0
    ok = _gpmi(_k32.GetCurrentProcess(), ctypes.byref(c), c.cb)
    if not ok:
        return -1.0, -1.0
    return c.WorkingSetSize / 1048576.0, c.PeakWorkingSetSize / 1048576.0


def rss_mb():
    return _sample()[0]


def peak_mb():
    return _sample()[1]


def wait_loaded(lib, seconds, label=''):
    """等 asr_state 离开 0（1=就绪 / -1=失败），返回 (state, 峰值RSS)。"""
    hi = rss_mb()
    deadline = time.time() + seconds
    while time.time() < deadline:
        time.sleep(0.25)
        hi = max(hi, rss_mb())
        st = lib.mutsurelay_asr_state()
        if st != 0:
            return st, hi
    return lib.mutsurelay_asr_state(), hi


def wait_idle(lib, seconds):
    """等到 asr_state 回到 0（空模型目录 = 主动卸载，不是失败）。"""
    deadline = time.time() + seconds
    while time.time() < deadline:
        time.sleep(0.25)
        if lib.mutsurelay_asr_state() == 0:
            time.sleep(0.5)   # 让 drop 走完
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dll', default=DEFAULT_DLL)
    ap.add_argument('--cycles', type=int, default=1, help='加载→卸载 重复轮数（看残留）')
    ap.add_argument('--model', default=MODEL_DIR)
    args = ap.parse_args()
    dll = os.path.abspath(args.dll)
    dll_dir = os.path.dirname(dll)

    print('=== 模型文件 ===')
    if os.path.isdir(args.model):
        total = 0.0
        for n in sorted(os.listdir(args.model)):
            p = os.path.join(args.model, n)
            total += os.path.getsize(p) / 1048576.0
            print(f'  {os.path.getsize(p)/1048576.0:9.1f} MB  {n}')
        print(f'  合计 {total:.1f} MB')
    else:
        print('  模型目录不存在:', args.model)

    base = rss_mb()
    print(f'\n[0] python 进程基线 RSS = {base:.1f} MB')

    os.add_dll_directory(dll_dir)
    for f in glob.glob(os.path.join(dll_dir, '*.dll')):
        try:
            ctypes.CDLL(f)
        except Exception:
            pass

    lib = ctypes.CDLL(dll)
    print(f'    DLL = {dll}')
    lib.mutsurelay_init.argtypes = [ctypes.c_char_p]
    lib.mutsurelay_init.restype = ctypes.c_int
    lib.mutsurelay_init_asr.argtypes = [ctypes.c_char_p]
    lib.mutsurelay_init_asr.restype = ctypes.c_int
    lib.mutsurelay_reload_asr.argtypes = [ctypes.c_char_p]
    lib.mutsurelay_reload_asr.restype = ctypes.c_int
    lib.mutsurelay_asr_state.restype = ctypes.c_int

    after_load = rss_mb()
    print(f'[1] 加载 DLL 后            RSS = {after_load:.1f} MB   (+{after_load-base:.1f})')

    lib.mutsurelay_init(b'')
    time.sleep(1.5)
    after_init = rss_mb()
    print(f'[2] init(空模型目录) 后    RSS = {after_init:.1f} MB   (+{after_init-after_load:.1f})  '
          f'(解码线程 + 环形缓冲，不含模型)')

    # 真正的加载入口：reload_asr 是 forced，init_asr 在懒加载后不会再拉模型
    print('\n[3] 加载 ASR 模型（mutsurelay_reload_asr，异步）...')
    lib.mutsurelay_reload_asr(args.model.encode('utf-8'))
    t0 = time.time()
    st, hi = wait_loaded(lib, 40)
    load_s = time.time() - t0
    final = rss_mb()
    print(f'[4] asr_state={st}  加载耗时 {load_s:.1f}s  RSS = {final:.1f} MB   '
          f'(+{final-after_init:.1f} 来自模型)')
    model_mb = sum(os.path.getsize(os.path.join(args.model, f))
                   for f in os.listdir(args.model)) / 1048576.0
    print(f'\n>>> 模型加载增量 ≈ {final-after_init:.0f} MB（模型文件本身 {model_mb:.0f} MB，'
          f'放大 {(final-after_init)/max(model_mb,1):.2f}×）')

    # 卸载：空目录 → create_recognizer 返回 None → 旧 recognizer 被 drop
    print('\n[5] 卸载模型（reload_asr 传空目录）...')
    lib.mutsurelay_reload_asr(b'')
    wait_idle(lib, 20)
    released = rss_mb()
    print(f'>>> 卸载后 RSS = {released:.1f} MB（历史峰值 {peak_mb():.1f} MB）')
    print(f'>>> 相对"未加载模型"基线 {after_init:.1f} MB 的残留 = {released-after_init:+.1f} MB')
    if released < after_init + 60:
        print('>>> 结论：内存基本归还给 OS —— "空闲卸载"方案可行')
    else:
        print('>>> 结论：内存**未**归还（onnxruntime 保留 arena）—— 卸载方案收益有限')

    # 反复重建看有没有累积（arena 碎片化的判据）
    if args.cycles > 1:
        print(f'\n[6] 反复加载→卸载 ×{args.cycles}（看残留是否累积）')
        marks = []
        for i in range(args.cycles):
            lib.mutsurelay_reload_asr(args.model.encode('utf-8'))
            st, hi = wait_loaded(lib, 40)
            loaded = rss_mb()
            lib.mutsurelay_reload_asr(b'')
            wait_idle(lib, 20)
            idle = rss_mb()
            marks.append((i + 1, loaded, idle, hi))
            print(f'    第 {i+1} 轮: 装载 {loaded:7.1f} MB  卸载后 {idle:7.1f} MB  '
                  f'峰值 {hi:7.1f} MB  (state={st})')
        first_i, last_i = marks[0][2], marks[-1][2]
        print(f'\n>>> 卸载后 RSS 从 {first_i:.1f} MB 漂到 {last_i:.1f} MB'
              f'（{last_i-first_i:+.1f} MB / {len(marks)} 轮）')
        if last_i - first_i > 60:
            print('>>> 有累积 → onnxruntime arena 没把页还给 OS，值得去查 session 选项')
        else:
            print('>>> 无明显累积 → 反复重建不会持续吃内存')


if __name__ == '__main__':
    main()
