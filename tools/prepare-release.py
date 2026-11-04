import json, pathlib, subprocess, sys, re, os
from release_artifacts import certificate_sha256, validate_apk_identity

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
verification = subprocess.run([str(build_tools / 'apksigner'), 'verify', '--print-certs', str(apk)],
                              capture_output=True, text=True, check=True)
signatures = verification.stdout + '\n' + verification.stderr
try:
    cert = certificate_sha256(signatures)
except ValueError as error:
    # apksigner emits public certificate metadata only; this diagnoses format
    # drift without printing any key.properties, passwords or signing seeds.
    print('Android build tools:', build_tools.name, file=sys.stderr)
    print(signatures, file=sys.stderr)
    raise SystemExit(str(error))
badging = subprocess.check_output([str(build_tools / 'aapt'), 'dump', 'badging', str(apk)], text=True)
try:
    validate_apk_identity(badging, version, build)
except ValueError as error:
    raise SystemExit(str(error))
out = root / 'release-dist'; out.mkdir(exist_ok=True)
packed = json.loads(subprocess.check_output(['npm', 'pack', '--json', '--pack-destination', str(out)], text=True))[0]
subprocess.run(['node', 'tools/release.mjs', '--tag', tag, '--apk', str(apk), '--plugin', str(out / packed['filename']),
                '--certificate', cert, '--out', str(out)], check=True)
