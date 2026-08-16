# Archive a release: copies the APK and packs the plugin tarball into
# dsh-mobile-app/dist/ with versioned filenames. Version comes from pubspec.yaml;
# plugin version is kept in sync (App version = plugin version = git tag).
# Run after: flutter build apk --release
$ErrorActionPreference = 'Stop'
$appDir = Split-Path -Parent $PSScriptRoot   # dsh-mobile-app/
$repoDir = Split-Path -Parent $appDir        # repo root
$apk = Join-Path $appDir 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) {
    Write-Error "APK not found: $apk - run 'flutter build apk --release' first"
    exit 1
}
$pubspec = Get-Content (Join-Path $appDir 'pubspec.yaml') -Raw
$ver = ([regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)')).Groups[1].Value
if (-not $ver) { Write-Error 'Cannot parse version from pubspec.yaml'; exit 1 }
$dist = Join-Path $appDir 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null

# 1) App APK
$apkOut = Join-Path $dist "DSH-Remote-v$ver.apk"
Copy-Item $apk $apkOut -Force
Write-Output ("Archived: " + $apkOut + " (" + [math]::Round((Get-Item $apkOut).Length / 1MB, 1) + " MB)")

# 2) Plugin tarball (npm pack, local only - no network needed)
# npm writes notices to stderr - route them away so the script exits cleanly.
Push-Location $repoDir
try {
    $null = cmd /c "npm pack --pack-destination `"$dist`" 2>nul"
} finally {
    Pop-Location
}
$tgzOut = Join-Path $dist "dsh-mobile-remote-$ver.tgz"
if (Test-Path $tgzOut) {
    Write-Output ("Archived: " + $tgzOut + " (" + [math]::Round((Get-Item $tgzOut).Length / 1KB, 0) + " KB)")
} else {
    Write-Warning "Plugin tarball not found at $tgzOut - check npm pack output"
}
