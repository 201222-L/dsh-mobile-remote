#!/usr/bin/env bash
# Archive a release (Linux/WSL，与 package-release.ps1 等价)，并生成自动更新主机源的 manifest.json（App 3.0.0+8 起）。
# 用法：构建后执行 `bash dsh-mobile-app/tools/package-release.sh`；
#       设置 UPDATE_DIR=<插件 updateDir> 可将 APK+manifest 一并拷入主机更新目录。
set -euo pipefail

app_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$app_dir/.." && pwd)"

apk="$app_dir/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$apk" ]; then
    echo "APK not found: $apk — run 'flutter build apk --release' first" >&2
    exit 1
fi

full_ver="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)([[:space:]]+#.*)?[[:space:]]*$/\1/p' "$app_dir/pubspec.yaml" | head -1)"
[ -n "$full_ver" ] || { echo "Cannot parse version (expected X.Y.Z+N) from pubspec.yaml" >&2; exit 1; }
ver="${full_ver%+*}"
build_num="${full_ver##*+}"

if [ -n "${MANIFEST_VERSION:-}" ]; then
    if [ "${ALLOW_TEST_MANIFEST_VERSION:-}" != "1" ]; then
        echo "MANIFEST_VERSION is test-only; set ALLOW_TEST_MANIFEST_VERSION=1 explicitly" >&2
        exit 1
    fi
    if [[ ! "$MANIFEST_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$ ]]; then
        echo "MANIFEST_VERSION must have the form X.Y.Z+N" >&2
        exit 1
    fi
    override_main="${BASH_REMATCH[1]}"
    override_build="${BASH_REMATCH[2]}"
    if [ "$override_main" != "$ver" ] || (( 10#$override_build <= 10#$build_num )); then
        echo "Test manifest version must keep $ver and use a build number greater than $build_num" >&2
        exit 1
    fi
    full_ver="$MANIFEST_VERSION"
elif [ "${ALLOW_TEST_MANIFEST_VERSION:-}" = "1" ]; then
    echo "ALLOW_TEST_MANIFEST_VERSION=1 requires MANIFEST_VERSION" >&2
    exit 1
fi

dist="$app_dir/dist"
mkdir -p "$dist"

# 1) App APK
apk_out="$dist/DSH-Remote-v$ver.apk"
cp "$apk" "$apk_out"
echo "Archived: $apk_out ($(du -h "$apk_out" | cut -f1))"

# 2) 插件 tarball（npm pack，本地无网络；输出名与 PowerShell 脚本统一）
npm_tgz="$dist/dsh-mobile-remote-$ver.tgz"
tgz_out="$dist/dsh-mobile-remote-v$ver.tgz"
(cd "$repo_dir" && npm pack --pack-destination "$dist" >/dev/null)
if [ -f "$npm_tgz" ]; then
    mv -f "$npm_tgz" "$tgz_out"
fi
if [ ! -f "$tgz_out" ]; then
    echo "Plugin tarball not found at $tgz_out" >&2
    exit 1
fi
echo "Archived: $tgz_out ($(du -h "$tgz_out" | cut -f1))"

# 3) manifest.json（共享生成器：合法 JSON / 无 BOM / notes=CHANGELOG 最新条目全文 / sha256+size）
manifest="$dist/manifest.json"
node "$app_dir/tools/gen-manifest.js" \
    --apk "$apk_out" \
    --version "$full_ver" \
    --changelog "$repo_dir/CHANGELOG.md" \
    --out "$manifest"

# 4) 可选：拷入插件 updateDir（应用「主机源」更新通道）
if [ -n "${UPDATE_DIR:-}" ]; then
    mkdir -p "$UPDATE_DIR"
    cp "$apk_out" "$manifest" "$UPDATE_DIR/"
    echo "Copied to updateDir: $UPDATE_DIR"
fi