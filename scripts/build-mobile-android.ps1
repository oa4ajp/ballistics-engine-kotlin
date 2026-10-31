# Build libballistics_engine.so for the Ballistics Insight Android app.
#
# Uses cargo-ndk (install: `cargo install cargo-ndk`; needs ANDROID_NDK_HOME).
# ABIs: arm64-v8a + x86_64 (armeabi-v7a/x86 dropped - no measured user base).
# 16 KB page alignment is required for Google Play (Android 15+ devices).
# A DT_SONAME is required for a consumer to link the result portably (MBA-1541); this script
# sets one and then reads it back off the artifacts before declaring success.
# Mobile feature set matches iOS: bridge + ffi + pdf + profile-import, no online/cli.
#
# Output: target/mobile/jniLibs/<abi>/libballistics_engine.so
#
# Usage:
#   .\scripts\build-mobile-android.ps1
#
# Requirements:
#   - cargo-ndk installed  : cargo install cargo-ndk
#   - ANDROID_NDK_HOME set : $env:ANDROID_NDK_HOME = "C:\path\to\ndk"
#   - Execution policy     : Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#                            (or run as: powershell -ExecutionPolicy Bypass -File .\scripts\build-mobile-android.ps1)

# Equivalent of `set -euo pipefail`: stop on any error, treat unset variables as errors.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Resolve ENGINE_DIR (parent of the directory this script lives in)
# Equivalent of: ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# ---------------------------------------------------------------------------
$ENGINE_DIR = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $ENGINE_DIR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$FEATURES = "bridge,ffi,pdf,profile-import"
$OUT      = Join-Path $ENGINE_DIR "target\mobile\jniLibs"
$SONAME   = "libballistics_engine.so"

# ---------------------------------------------------------------------------
# Pre-flight checks
# Equivalent of: command -v cargo-ndk || { echo ...; exit 1; }
#                : "${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to your NDK path}"
# ---------------------------------------------------------------------------
if (-not (Get-Command cargo-ndk -ErrorAction SilentlyContinue)) {
    Write-Error "cargo-ndk not installed: cargo install cargo-ndk"
    exit 1
}

if (-not $env:ANDROID_NDK_HOME) {
    Write-Error "ANDROID_NDK_HOME is not set. Set it to your NDK path, e.g.:`n  `$env:ANDROID_NDK_HOME = 'C:\path\to\ndk'"
    exit 1
}

# ---------------------------------------------------------------------------
# Add Rust targets
# Equivalent of: rustup target add aarch64-linux-android x86_64-linux-android >/dev/null
# ---------------------------------------------------------------------------
rustup target add aarch64-linux-android x86_64-linux-android | Out-Null

# ---------------------------------------------------------------------------
# Clean output directory
# Equivalent of: rm -rf "$OUT"
# ---------------------------------------------------------------------------
if (Test-Path $OUT) {
    Remove-Item -Recurse -Force $OUT
}

# ---------------------------------------------------------------------------
# Build
# MBA-1541: -soname is not optional for these artifacts. Without DT_SONAME the linker
# records whatever path the consumer linked against, so a CMake project using the ordinary
# `add_library(... SHARED IMPORTED)` + `IMPORTED_LOCATION /abs/path/libballistics_engine.so`
# pattern bakes that absolute HOST path into its own DT_NEEDED, and the app then fails to
# dlopen the library on device. An external integrator hit exactly that and had to fall back
# to plain -L/-l.
#
# It goes after `--`, on `rustc`, rather than into RUSTFLAGS next to max-page-size, because
# RUSTFLAGS reaches EVERY crate in the graph and a dependency here also declares a cdylib
# (printpdf), which cargo-ndk copies into the same jniLibs directory. A soname in RUSTFLAGS
# stamps `libballistics_engine.so` onto that file too, leaving two different libraries in one
# directory claiming one name. `cargo rustc`'s trailing arguments apply to this crate alone.
# max-page-size stays in RUSTFLAGS on purpose: Play's 16 KB requirement is about every .so
# shipped in the APK, not just ours.
#
# Equivalent of:
#   RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,-z,max-page-size=16384" \
#     cargo ndk -t arm64-v8a -t x86_64 -o "$OUT" \
#     rustc --lib --release --no-default-features --features "$FEATURES" \
#     -- -C link-arg=-Wl,-soname,"$SONAME"
# ---------------------------------------------------------------------------

# Preserve any existing RUSTFLAGS (mirrors ${RUSTFLAGS:-} in bash).
$prevRustFlags  = $env:RUSTFLAGS
$env:RUSTFLAGS  = (($env:RUSTFLAGS, "-C link-arg=-Wl,-z,max-page-size=16384") -join " ").Trim()

try {
    cargo ndk -t arm64-v8a -t x86_64 -o $OUT `
        rustc --lib --release --no-default-features --features $FEATURES `
        -- -C link-arg=-Wl,-soname,$SONAME

    if ($LASTEXITCODE -ne 0) {
        Write-Error "cargo ndk build failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    # Restore RUSTFLAGS regardless of build success/failure.
    $env:RUSTFLAGS = $prevRustFlags
}

# ---------------------------------------------------------------------------
# Locate llvm-readelf
# Prefer the NDK's own readelf: this script already requires ANDROID_NDK_HOME,
# so it is the one ELF reader we know is installed.
# Equivalent of the bash candidate-loop + fallback to `command -v`.
# ---------------------------------------------------------------------------
$READELF = $null

$prebuiltRoot = Join-Path $env:ANDROID_NDK_HOME "toolchains\llvm\prebuilt"
if (Test-Path $prebuiltRoot) {
    foreach ($dir in Get-ChildItem -Directory $prebuiltRoot) {
        $candidate = Join-Path $dir.FullName "bin\llvm-readelf.exe"
        if (Test-Path $candidate) {
            $READELF = $candidate
            break
        }
    }
}

if (-not $READELF) {
    $cmd = Get-Command llvm-readelf -ErrorAction SilentlyContinue
    if ($cmd) { $READELF = $cmd.Source }
}
if (-not $READELF) {
    $cmd = Get-Command readelf -ErrorAction SilentlyContinue
    if ($cmd) { $READELF = $cmd.Source }
}
if (-not $READELF) {
    Write-Error "no llvm-readelf/readelf found; cannot verify DT_SONAME"
    exit 1
}

# ---------------------------------------------------------------------------
# Verify DT_SONAME on every .so under $OUT
# Two checks, because the fix has two ways to go wrong: the soname can go
# missing, and it can land on a file that is not ours (see RUSTFLAGS note).
# Both fail the build here rather than reaching a device.
#
# Equivalent of the bash for-loop with sed extraction:
#   claimed="$("$READELF" -d "$so" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
# ---------------------------------------------------------------------------
$checked = 0

$soFiles = Get-ChildItem -Path $OUT -Recurse -Filter "*.so" -ErrorAction SilentlyContinue
foreach ($so in $soFiles) {
    # Extract the value between [ ] on the SONAME line from readelf -d output.
    # Example line:
    #   0x000000000000000e (SONAME)   Library soname: [libballistics_engine.so]
    $readelfOutput = & $READELF -d $so.FullName
    $claimed = $null
    foreach ($line in $readelfOutput) {
        if ($line -match 'SONAME.*\[(.+)\]') {
            $claimed = $Matches[1]
            break
        }
    }

    $soBaseName = $so.Name

    if ($soBaseName -eq $SONAME) {
        $checked++
        if ($claimed -eq $SONAME) {
            Write-Host "    DT_SONAME ok: $($so.FullName)"
        } else {
            $displayClaimed = if ($claimed) { $claimed } else { "<none>" }
            Write-Error "FAIL: $($so.FullName) declares DT_SONAME '$displayClaimed', expected '$SONAME'."
            Write-Error "      A consumer linking it by absolute path would bake that path into its own"
            Write-Error "      DT_NEEDED and fail to dlopen on device. Check the -soname arg above."
            exit 1
        }
    } elseif ($claimed -eq $SONAME) {
        Write-Error "FAIL: $($so.FullName) also claims DT_SONAME '$SONAME'."
        Write-Error "      Two libraries in one jniLibs directory answering to one name. The -soname"
        Write-Error "      arg has leaked out of this crate - check it is on 'cargo rustc --', not in"
        Write-Error "      RUSTFLAGS."
        exit 1
    }
}

if ($checked -eq 0) {
    Write-Error "FAIL: no $SONAME produced under $OUT"
    exit 1
}

# ---------------------------------------------------------------------------
# Final summary
# Equivalent of:
#   echo "OK: $OUT (features: $FEATURES, engine $(grep -m1 '^version' Cargo.toml | cut -d'"' -f2))"
#   find "$OUT" -name '*.so' -exec ls -la {} \;
# ---------------------------------------------------------------------------
$versionLine = Select-String -Path (Join-Path $ENGINE_DIR "Cargo.toml") -Pattern '^version' |
               Select-Object -First 1
$version = if ($versionLine -and $versionLine.Line -match '"(.+)"') { $Matches[1] } else { "unknown" }

Write-Host "OK: $OUT (features: $FEATURES, engine $version)"

Get-ChildItem -Path $OUT -Recurse -Filter "*.so" |
    ForEach-Object { Write-Host ("{0,12} {1}" -f $_.Length, $_.FullName) }
