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
$versionMatch = [regex]::Match($pubspec, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)(?:[ \t]+#[^\r\n]*)?[ \t\r]*$')
if (-not $versionMatch.Success) { Write-Error 'Cannot parse version (expected X.Y.Z+N) from pubspec.yaml'; exit 1 }
$ver = $versionMatch.Groups[1].Value
$buildText = $versionMatch.Groups[2].Value
$buildNumber = [long]::Parse($buildText)
$fullVersion = "$ver+$buildText"

if ($env:MANIFEST_VERSION) {
    if ($env:ALLOW_TEST_MANIFEST_VERSION -ne '1') {
        Write-Error 'MANIFEST_VERSION is test-only; set ALLOW_TEST_MANIFEST_VERSION=1 explicitly'
        exit 1
    }
    $overrideMatch = [regex]::Match($env:MANIFEST_VERSION, '^(\d+\.\d+\.\d+)\+(\d+)$')
    if (-not $overrideMatch.Success -or $overrideMatch.Groups[1].Value -ne $ver) {
        Write-Error "Test manifest version must keep $ver and have the form X.Y.Z+N"
        exit 1
    }
    $overrideBuild = [long]::Parse($overrideMatch.Groups[2].Value)
    if ($overrideBuild -le $buildNumber) {
        Write-Error "Test manifest build must be greater than the APK build $buildNumber"
        exit 1
    }
    $fullVersion = $env:MANIFEST_VERSION
} elseif ($env:ALLOW_TEST_MANIFEST_VERSION -eq '1') {
    Write-Error 'ALLOW_TEST_MANIFEST_VERSION=1 requires MANIFEST_VERSION'
    exit 1
}
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
$packed = Join-Path $dist "dsh-mobile-remote-$ver.tgz"
$tgzOut = Join-Path $dist "dsh-mobile-remote-v$ver.tgz"
if (Test-Path $packed) {
    # 命名对齐历史发布惯例：dsh-mobile-remote-vX.Y.Z.tgz（npm pack 原生输出不含 v）
    Move-Item $packed $tgzOut -Force
    Write-Output ("Archived: " + $tgzOut + " (" + [math]::Round((Get-Item $tgzOut).Length / 1KB, 0) + " KB)")
} elseif (Test-Path $tgzOut) {
    Write-Output ("Archived: " + $tgzOut + " (" + [math]::Round((Get-Item $tgzOut).Length / 1KB, 0) + " KB)")
} else {
    Write-Warning "Plugin tarball not found - check npm pack output"
}

# 3) Update manifest for the host update source.
$manifest = Join-Path $dist 'manifest.json'
node (Join-Path $PSScriptRoot 'gen-manifest.js') --apk $apkOut --version $fullVersion --changelog (Join-Path $repoDir 'CHANGELOG.md') --out $manifest
if ($LASTEXITCODE -ne 0) { Write-Error "gen-manifest.js failed with exit code $LASTEXITCODE"; exit 1 }
if ($env:UPDATE_DIR) {
    New-Item -ItemType Directory -Force -Path $env:UPDATE_DIR | Out-Null
    Copy-Item $apkOut $manifest $env:UPDATE_DIR -Force
    Write-Output ("Copied to updateDir: " + $env:UPDATE_DIR)
}
