"""Validate public Android build-tool output before signing a release manifest."""
import re


def certificate_sha256(output):
    # Recent apksigner versions annotate signers with SDK ranges. The signer
    # label is presentation; the complete certificate fingerprint is the fact.
    fingerprints = {
        match.group(1).lower()
        for line in output.splitlines()
        if re.match(r'\s*Signer\b', line, re.IGNORECASE)
        for match in [re.search(
            r'\bcertificate SHA-256 digest:\s*([0-9a-f]{64})\s*$',
            line, re.IGNORECASE)]
        if match
    }
    if len(fingerprints) != 1:
        raise ValueError('APK verification must report exactly one signing certificate SHA-256.')
    if re.search(r'\bAndroid Debug\b', output, re.IGNORECASE):
        raise ValueError('An official release cannot use a debug certificate.')
    return fingerprints.pop()


def validate_apk_identity(output, version, build):
    package = next((line for line in output.splitlines() if line.startswith('package:')), '')
    fields = dict(re.findall(r"(\w+)='([^']*)'", package))
    if (fields.get('name') != 'com.dsh.remote'
            or fields.get('versionCode') != str(build)
            or fields.get('versionName') != version):
        raise ValueError('Actual APK identity disagrees with the release.')
