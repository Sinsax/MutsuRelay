# Build script for MutsuRelay native library
param(
    [ValidateSet("debug", "release")]
    [string]$Profile = "release"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath

Write-Host "=== Building MutsuRelay Native Library ($Profile) ===" -ForegroundColor Cyan

# Ensure Rust is installed
$rustc = Get-Command "rustc" -ErrorAction SilentlyContinue
if (-not $rustc) {
    Write-Error "Rust is not installed. Install from https://rustup.rs"
    exit 1
}

Write-Host "Rust version: $(rustc --version)" -ForegroundColor Green

# Build
Push-Location $ProjectRoot
try {
    if ($Profile -eq "release") {
        cargo build --release
        $targetDir = "target\release"
    } else {
        cargo build
        $targetDir = "target\debug"
    }

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Build failed"
        exit 1
    }

    # Copy to Flutter windows plugin directory
    $flutterPluginDir = Join-Path $ProjectRoot "..\windows\mutsurelay_native"
    if (-not (Test-Path $flutterPluginDir)) {
        New-Item -ItemType Directory -Path $flutterPluginDir -Force | Out-Null
    }

    $dllFile = Join-Path $targetDir "mutsurelay_native.dll"
    $pdbFile = Join-Path $targetDir "mutsurelay_native.pdb"
    $libFile = Join-Path $targetDir "mutsurelay_native.lib"

    if (Test-Path $dllFile) {
        Copy-Item -Path $dllFile -Destination $flutterPluginDir -Force
        Write-Host "Copied DLL to $flutterPluginDir" -ForegroundColor Green
    }
    # Copy runtime dependencies (sherpa-onnx, onnxruntime)
    @('sherpa-onnx-c-api.dll', 'sherpa-onnx-cxx-api.dll', 'onnxruntime.dll', 'onnxruntime_providers_shared.dll') | ForEach-Object {
        $dep = Join-Path $targetDir $_
        if (Test-Path $dep) {
            Copy-Item -Path $dep -Destination $flutterPluginDir -Force
        }
    }
    if (Test-Path $pdbFile) {
        Copy-Item -Path $pdbFile -Destination $flutterPluginDir -Force
    }
    if (Test-Path $libFile) {
        Copy-Item -Path $libFile -Destination $flutterPluginDir -Force
    }

    # Also copy to build output so Windows finds dependencies at runtime
    $flutterBuildDir = Join-Path $ProjectRoot "..\build\windows\x64\runner\Debug"
    if (Test-Path $flutterBuildDir) {
        Copy-Item -Path "$flutterPluginDir\*" -Destination $flutterBuildDir -Force
    }

    # Bundle ASR model into build output (if present)
    $modelDir = Join-Path $ProjectRoot "..\asr\model"
    if (Test-Path $modelDir) {
        $buildModelDir = Join-Path $flutterBuildDir "asr\model"
        New-Item -ItemType Directory -Path $buildModelDir -Force | Out-Null
        Copy-Item -Path "$modelDir\*" -Destination $buildModelDir -Force
        Write-Host "Bundled ASR model to $buildModelDir" -ForegroundColor Green
    }

    Write-Host "=== Build complete ===" -ForegroundColor Cyan
} finally {
    Pop-Location
}
