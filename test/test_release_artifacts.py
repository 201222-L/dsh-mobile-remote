import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from release_artifacts import certificate_sha256, validate_apk_identity


class CertificateOutputTests(unittest.TestCase):
    fingerprint = 'a1' * 32

    def test_accepts_numbered_sdk_range_and_build_tools_37_signers(self):
        for label in ['Signer #1', 'Signer (minSdkVersion=24, maxSdkVersion=2147483647) #1',
                      'Signer (minSdkVersion=24, maxSdkVersion=32)',
                      'V2 Signer:', 'V3.1 Signer:']:
            with self.subTest(label=label):
                self.assertEqual(certificate_sha256(
                    f'{label} certificate DN: CN=DSH Remote\n'
                    f'{label} certificate SHA-256 digest: {self.fingerprint.upper()}\n'),
                    self.fingerprint)

    def test_accepts_same_signer_repeated_for_sdk_ranges(self):
        text = '\n'.join(f'Signer (minSdkVersion={sdk}) certificate SHA-256 digest: {self.fingerprint}'
                         for sdk in [24, 33])
        self.assertEqual(certificate_sha256(text), self.fingerprint)

    def test_rejects_missing_short_or_non_signer_certificate(self):
        for text in ['', 'Number of signers: 0', 'Signer #1 certificate SHA-256 digest: abcd',
                     f'Source Stamp Signer certificate SHA-256 digest: {self.fingerprint}',
                     f'Signer #1 certificate SHA-256 digest: {self.fingerprint}extra']:
            with self.subTest(output=text):
                with self.assertRaises(ValueError):
                    certificate_sha256(text)

    def test_rejects_multiple_different_certificates(self):
        with self.assertRaises(ValueError):
            certificate_sha256(f'Signer #1 certificate SHA-256 digest: {self.fingerprint}\n'
                               f'Signer #2 certificate SHA-256 digest: {"b2" * 32}')

    def test_rejects_debug_certificate(self):
        with self.assertRaisesRegex(ValueError, 'debug certificate'):
            certificate_sha256(f'Signer #1 certificate DN: CN=Android Debug,O=Android,C=US\n'
                               f'Signer #1 certificate SHA-256 digest: {self.fingerprint}')


class ApkIdentityTests(unittest.TestCase):
    def test_checks_identity_without_depending_on_attribute_order(self):
        validate_apk_identity("package: versionName='3.2.4-alpha.1' name='com.dsh.remote' versionCode='32'",
                              '3.2.4-alpha.1', 32)

    def test_rejects_wrong_version_package_or_build(self):
        for name, version, build in [('other.package', '3.2.4-alpha.1', '32'),
                                     ('com.dsh.remote', '3.2.3', '32'),
                                     ('com.dsh.remote', '3.2.4-alpha.1', '31')]:
            with self.assertRaises(ValueError):
                validate_apk_identity(f"package: name='{name}' versionName='{version}' versionCode='{build}'",
                                      '3.2.4-alpha.1', 32)


if __name__ == '__main__':
    unittest.main()
