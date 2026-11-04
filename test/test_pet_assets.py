import hashlib
import json
from pathlib import Path
import unittest


APP = Path(__file__).resolve().parents[1] / "dsh-mobile-app"


def frame_durations(data):
    offset = 12
    durations = []
    while offset + 8 <= len(data):
        tag = data[offset:offset + 4]
        length = int.from_bytes(data[offset + 4:offset + 8], "little")
        if tag == b"ANMF":
            durations.append(int.from_bytes(data[offset + 20:offset + 23], "little"))
        offset += 8 + length + length % 2
    return durations


class PetAssetsTest(unittest.TestCase):
    def test_shared_animations_match_playback_manifest_and_size_budget(self):
        manifest = json.loads((APP / "assets/pet-manifest.json").read_text(encoding="utf-8"))
        assets = APP / "assets/pet"
        self.assertFalse((APP / "android/app/src/main/assets/pet").exists())
        self.assertEqual(len(manifest["clips"]), 16)
        referenced = {clip["file"] for clip in manifest["clips"].values()}
        self.assertEqual(referenced, {p.name for p in assets.glob("*.webp")})
        digests = [hashlib.sha256((assets / name).read_bytes()).digest() for name in referenced]
        self.assertEqual(len(digests), len(set(digests)), "identical animations must share a file")
        for name, clip in manifest["clips"].items():
            with self.subTest(clip=name):
                durations = frame_durations((assets / clip["file"]).read_bytes())
                self.assertEqual(len(durations), clip["frames"])
                self.assertEqual(set(durations), {clip["frameMs"]})
        self.assertLess(sum(p.stat().st_size for p in assets.iterdir()), 7 * 1024 * 1024)
        for name in ["idle", "head_pat", "poke", "tail"]:
            self.assertTrue((assets / f"{name}.webp").is_file())
            self.assertTrue((assets / f"static-{name}.png").is_file())
        self.assertTrue((APP / "assets/PET-LICENSE.txt").is_file())


if __name__ == "__main__":
    unittest.main()
