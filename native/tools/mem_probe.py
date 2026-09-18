import ctypes, os, sys, time, glob
from ctypes import wintypes

DLLDIR = r'F:\para\Code\MutsuRelay\native\target\debug'
DLL = os.path.join(DLLDIR, 'mutsurelay_native.dll')

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

print('=== 模型文件 ===')
model_dir = r'F:\para\Code\MutsuRelay\asr\model'
if os.path.isdir(model_dir):
    for n in sorted(os.listdir(model_dir)):
        p = os.path.join(model_dir, n)
        print(f'  {os.path.getsize(p)/1048576.0:9.1f} MB  {n}')
else:
    print('  模型目录不存在:', model_dir)

base = rss_mb()
print(f'\n[0] python 进程基线 RSS = {base:.1f} MB')

os.add_dll_directory(DLLDIR)
for f in glob.glob(os.path.join(DLLDIR, '*.dll')):
    try: ctypes.CDLL(f)
    except Exception: pass

lib = ctypes.CDLL(DLL)
lib.mutsurelay_init.argtypes = [ctypes.c_char_p]
lib.mutsurelay_init.restype = ctypes.c_int
lib.mutsurelay_init_asr.argtypes = [ctypes.c_char_p]
lib.mutsurelay_init_asr.restype = ctypes.c_int
lib.mutsurelay_asr_state.restype = ctypes.c_int

after_load = rss_mb()
print(f'[1] 加载 DLL 后            RSS = {after_load:.1f} MB   (+{after_load-base:.1f})')

# 用空的 model_dir 初始化：解码线程起来，但不建 recognizer
lib.mutsurelay_init(b'')
time.sleep(1.5)
after_init = rss_mb()
print(f'[2] init(空模型目录) 后    RSS = {after_init:.1f} MB   (+{after_init-after_load:.1f})  '
      f'(解码线程 + 环形缓冲，不含模型)')

# 真正加载 240MB 模型
print('\n[3] 正在加载 ASR 模型（异步 reload）...')
lib.mutsurelay_init_asr(model_dir.encode('utf-8'))
for i in range(30):
    time.sleep(0.5)
    st = lib.mutsurelay_asr_state()
    r = rss_mb()
    print(f'    t={0.5*(i+1):4.1f}s  asr_state={st}  RSS={r:7.1f} MB')
    if st != 0:
        break
final = rss_mb()
print(f'\n[4] 模型就绪后             RSS = {final:.1f} MB   (+{final-after_init:.1f} 来自模型)')
print(f'    峰值                      = {peak_mb():.1f} MB')
print(f'\n>>> 模型加载带来的增量 ≈ {final-after_init:.0f} MB'
      f'（模型文件本身 {sum(os.path.getsize(os.path.join(model_dir,f)) for f in os.listdir(model_dir))/1048576.0:.0f} MB）')

# ---- 关键问题：卸载模型后，内存到底还不还给操作系统？ ----
# init_asr 传空目录 → create_recognizer 返回 None → 旧 recognizer 被 drop。
print('\n[5] 卸载模型（init_asr 传空目录，旧 recognizer 被 drop）...')
lib.mutsurelay_init_asr(b'')
for i in range(12):
    time.sleep(0.5)
    print(f'    t={0.5*(i+1):4.1f}s  asr_state={lib.mutsurelay_asr_state()}  RSS={rss_mb():7.1f} MB')
released = rss_mb()
print(f'\n>>> 卸载后 RSS = {released:.1f} MB（历史峰值 {peak_mb():.1f} MB）')
print(f'>>> 相对"未加载模型"基线 {after_init:.1f} MB 的残留 = {released-after_init:+.1f} MB')
if released < after_init + 60:
    print('>>> 结论：内存基本归还给 OS —— "空闲卸载"方案可行')
else:
    print('>>> 结论：内存**未**归还（onnxruntime 保留 arena）—— 卸载方案收益有限')

