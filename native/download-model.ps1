# Download SenseVoice ASR model for MutsuRelay
# Run once before building: powershell -File download-model.ps1

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$ModelDir = Join-Path $ProjectRoot "..\asr\model"
$Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"

Write-Host "=== Downloading SenseVoice ASR Model ===" -ForegroundColor Cyan
Write-Host "URL: $Url" -ForegroundColor Gray
Write-Host "Target: $ModelDir" -ForegroundColor Gray

# Create target directory
New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null

# Check if already downloaded
if ((Test-Path (Join-Path $ModelDir "model.int8.onnx")) -and (Test-Path (Join-Path $ModelDir "tokens.txt"))) {
    Write-Host "Model already exists, skipping download." -ForegroundColor Green
    exit 0
}

# Download (requires curl or Invoke-WebRequest)
$archive = "$env:TEMP\sense-voice-model.tar.bz2"
Write-Host "Downloading (~200MB, may take a while)..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $Url -OutFile $archive

# Extract using tar (Windows 10 1803+ has built-in tar)
Write-Host "Extracting..." -ForegroundColor Yellow
tar -xf $archive -C "$env:TEMP\sense-voice-extracted"

# The archive extracts into a subdirectory; find model.int8.onnx
$extracted = Get-ChildItem -Recurse -Filter "model.int8.onnx" -LiteralPath "$env:TEMP\sense-voice-extracted" | Select-Object -First 1
if ($extracted) {
    $srcDir = $extracted.Directory.FullName
    Copy-Item -Path "$srcDir\*" -Destination $ModelDir -Force
    Remove-Item -Path "$env:TEMP\sense-voice-extracted" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Model extracted to $ModelDir" -ForegroundColor Green
} else {
    Write-Error "Extraction failed: model.int8.onnx not found in archive"
    exit 1
}

Remove-Item -Path $archive -Force -ErrorAction SilentlyContinue
Write-Host "=== Done ===" -ForegroundColor Cyan
