# Archive the release APK to dsh-mobile-app/dist/ with a versioned filename
# (version read from pubspec.yaml). Run after: flutter build apk --release
$ErrorActionPreference = 'Stop'
$appDir = Split-Path -Parent $PSScriptRoot   # dsh-mobile-app/
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
$out = Join-Path $dist "DSH-Remote-v$ver.apk"
Copy-Item $apk $out -Force
Write-Output ("Archived: " + $out + " (" + [math]::Round((Get-Item $out).Length / 1MB, 1) + " MB)")
