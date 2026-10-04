# 用 Windows SAPI 把 testdata/asr/ref/*.txt **逐行**合成为 16 kHz 单声道 WAV。
#
# 为什么逐行合成：TTS 在句号处的停顿只有几百毫秒且不可控；逐行合出来、再由
# build_test_audio.py 按"句间静音长度"拼装，长停顿才可复现（这是测试分段器
# 静音判停的关键）。
#
# 产物：testdata/asr/parts/<clip>/NN.wav（中间产物，已 gitignore）
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File native/tools/make_test_audio.ps1
#   powershell ... -File native/tools/make_test_audio.ps1 -Rate 2      # 全局语速微调
param(
  [string]$Root = '',
  [int]$Rate = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

if ([string]::IsNullOrWhiteSpace($Root)) {
  $here = Split-Path -Parent $MyInvocation.MyCommand.Path
  $Root = Join-Path $here '..\..\testdata\asr'
}
$Root = [IO.Path]::GetFullPath($Root)
$refDir = Join-Path $Root 'ref'
$partsRoot = Join-Path $Root 'parts'

if (-not (Test-Path $refDir)) { Write-Error "找不到参考文本目录: $refDir"; exit 1 }
Remove-Item -Recurse -Force $partsRoot -ErrorAction SilentlyContinue

# 语速范围 -10..10。基线 0；"快/慢"两个专项片段单独指定。
$rates = @{ '05_fast' = 6; '06_slow' = -4 }

$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voice = $synth.GetInstalledVoices() |
  Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -eq 'zh-CN' } |
  Select-Object -First 1
if (-not $voice) {
  Write-Error '系统里没有已启用的 zh-CN 语音（设置 → 时间和语言 → 语音 → 添加语音）'
  exit 1
}
$synth.SelectVoice($voice.VoiceInfo.Name)
Write-Host "语音: $($voice.VoiceInfo.Name)"

$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
  16000,
  [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
  [System.Speech.AudioFormat.AudioChannel]::Mono)

$total = 0
foreach ($file in Get-ChildItem -Path $refDir -Filter '*.txt' | Sort-Object Name) {
  $clip = [IO.Path]::GetFileNameWithoutExtension($file.Name)
  $dir = Join-Path $partsRoot $clip
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $lines = @(Get-Content -Path $file.FullName -Encoding UTF8 |
    Where-Object { $_.Trim().Length -gt 0 })
  if ($rates.ContainsKey($clip)) { $synth.Rate = [int]$rates[$clip] } else { $synth.Rate = $Rate }
  $i = 0
  foreach ($line in $lines) {
    $i++
    $out = Join-Path $dir ('{0:d2}.wav' -f $i)
    $synth.SetOutputToWaveFile($out, $fmt)
    $synth.Speak($line.Trim())
    $synth.SetOutputToNull()
  }
  $total += $i
  Write-Host ("{0,-14} {1,3} 句   rate={2}" -f $clip, $i, $synth.Rate)
}
$synth.Dispose()
Write-Host "完成：$total 句 → $partsRoot"
