import json, pathlib, subprocess, sys, re, os

root = pathlib.Path.cwd()
tag = sys.argv[1]
pkg = json.loads((root / 'package.json').read_text())
pub = (root / 'dsh-mobile-app/pubspec.yaml').read_text()
version, build = re.search(r'^version:\s*(\S+)\+(\d+)', pub, re.M).groups()
if tag != 'v' + pkg['version'] or version != pkg['version']:
    raise SystemExit('Tag, plugin and App versions disagree.')
apk = root / 'dsh-mobile-app/build/app/outputs/flutter-apk/app-release.apk'
sdk = pathlib.Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT', ''))
build_tools = sorted((sdk / 'build-tools').iterdir(), key=lambda p: [int(x) for x in re.findall(r'\d+', p.name)])[-1]
signatures = subprocess.check_output([str(build_tools / 'apksigner'), 'verify', '--print-certs', str(apk)], text=True)
cert = re.search(r'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]+)', signatures).group(1).lower()
if 'Android Debug' in signatures:
    raise SystemExit('An official release cannot use a debug certificate.')
badging = subprocess.check_output([str(build_tools / 'aapt'), 'dump', 'badging', str(apk)], text=True)
if not re.search(r"package: name='com\.dsh\.remote' versionCode='" + build + r"' versionName='" + re.escape(version) + "'", badging):
    raise SystemExit('Actual APK identity disagrees with the release.')
out = root / 'release-dist'; out.mkdir(exist_ok=True)
packed = json.loads(subprocess.check_output(['npm', 'pack', '--json', '--pack-destination', str(out)], text=True))[0]
subprocess.run(['node', 'tools/release.mjs', '--tag', tag, '--apk', str(apk), '--plugin', str(out / packed['filename']),
                '--certificate', cert, '--out', str(out)], check=True)
