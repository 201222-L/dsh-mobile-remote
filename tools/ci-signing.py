import os, pathlib, base64

root = pathlib.Path('dsh-mobile-app/android')
fields = {key: os.environ.get(key, '') for key in [
    'ANDROID_KEYSTORE_BASE64', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_PASSWORD', 'ANDROID_KEY_ALIAS']}
if not all(fields.values()):
    raise SystemExit('Official signing configuration is incomplete.')
if any('\n' in fields[k] or '\r' in fields[k] for k in fields if k != 'ANDROID_KEYSTORE_BASE64'):
    raise SystemExit('Signing properties must fit on one line.')
(root / 'ci-release.jks').write_bytes(base64.b64decode(fields['ANDROID_KEYSTORE_BASE64'], validate=True))
escape = lambda s: s.replace('\\', '\\\\').replace(':', '\\:').replace('=', '\\=')
(root / 'key.properties').write_text('\n'.join([
    'storeFile=ci-release.jks',
    'storePassword=' + escape(fields['ANDROID_STORE_PASSWORD']),
    'keyPassword=' + escape(fields['ANDROID_KEY_PASSWORD']),
    'keyAlias=' + escape(fields['ANDROID_KEY_ALIAS']),
]) + '\n')
