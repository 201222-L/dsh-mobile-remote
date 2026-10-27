#!/usr/bin/env python3
"""把 dsh-dafeiyu 的宠物帧转成手机端动画 WebP。

素材来源：QCYTSN/dsh-dafeiyu（MIT）→ PC2005-cloud/dsh-pet（MIT）。
本脚本只在更新素材时手动运行，运行结果（assets/pet/*.webp）随仓库提交；
构建 APK 不需要 Python 或 Pillow。

用法：
    python tools/build_pet_assets.py --source ../dsh-dafeiyu

依赖：Pillow >= 11（支持 animated WebP）。
"""
from __future__ import annotations

import argparse
import io
import json
import shutil
from pathlib import Path

from PIL import Image

# 只裁掉上下透明边，宽度保留完整画布：尾巴和吃 Token 动作会越出角色中心区。
CROP_BOX = (0, 6, 412, 333)
DEFAULT_SCALE = 0.70
DEFAULT_STEP = 2
DEFAULT_QUALITY = 50
ALPHA_QUALITY = 80


def build(source: Path, out_dir: Path, scale: float, step: int, quality: int) -> None:
    manifest_path = source / "assets" / "pet-manifest.json"
    frames_root = source / "assets" / "pet"
    license_path = source / "assets" / "dsh-pet-LICENSE.txt"
    for required in (manifest_path, frames_root, license_path):
        if not required.exists():
            raise SystemExit(f"missing source asset: {required}")

    source_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    out_dir.mkdir(parents=True, exist_ok=True)
    clips_out = out_dir / "pet"
    clips_out.mkdir(parents=True, exist_ok=True)

    clips: dict[str, dict] = {}
    total = 0
    for name, clip in source_manifest["clips"].items():
        source_frames = clip["frames"][::step]
        # 抽帧后补上最后一帧，保证一次性动作的落点完整。
        if source_frames[-1] != clip["frames"][-1]:
            source_frames.append(clip["frames"][-1])

        images = []
        for rel in source_frames:
            image = Image.open(frames_root / rel).convert("RGBA").crop(CROP_BOX)
            size = (round(image.width * scale), round(image.height * scale))
            images.append(image.resize(size, Image.LANCZOS))
        if not images:
            raise SystemExit(f"empty clip: {name}")

        buffer = io.BytesIO()
        images[0].save(
            buffer,
            format="WEBP",
            save_all=True,
            append_images=images[1:],
            duration=round(clip["frameMs"] * step),
            loop=0 if clip["loop"] else 1,
            quality=quality,
            alpha_quality=ALPHA_QUALITY,
            method=6,
        )
        output = clips_out / f"{name}.webp"
        output.write_bytes(buffer.getvalue())
        total += len(buffer.getvalue())
        clips[name] = {
            "file": f"{name}.webp",
            "frames": len(images),
            "frameMs": round(clip["frameMs"] * step),
            "loop": clip["loop"],
        }
        print(f"{name:18} {len(buffer.getvalue()) / 1024:8.1f} KB  frames={len(images)}")

    width = round(CROP_BOX[2] * scale)
    height = round((CROP_BOX[3] - CROP_BOX[1]) * scale)
    manifest = {
        "version": 1,
        "canvas": {"width": width, "height": height},
        "clips": clips,
        "stateMap": source_manifest["stateMap"],
        "workingActivityMap": source_manifest["workingActivityMap"],
        "idleMicroClips": source_manifest["idleMicroClips"],
        "idleMicroIntervalsMs": source_manifest["idleMicroIntervalsMs"],
        "interactionCooldownMs": source_manifest["interactionCooldownMs"],
        "source": {
            "project": "QCYTSN/dsh-dafeiyu",
            "upstream": "PC2005-cloud/dsh-pet",
            "license": "MIT",
            "scale": scale,
            "step": step,
            "quality": quality,
        },
    }
    (out_dir / "pet-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    shutil.copyfile(license_path, out_dir / "PET-LICENSE.txt")
    print(f"\nTOTAL {total / 1024 / 1024:.2f} MB  canvas={width}x{height}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="dsh-dafeiyu checkout")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "android"
        / "app"
        / "src"
        / "main"
        / "assets",
        help="Android assets root (default: app/src/main/assets)",
    )
    parser.add_argument("--scale", type=float, default=DEFAULT_SCALE)
    parser.add_argument("--step", type=int, default=DEFAULT_STEP, help="take every Nth frame")
    parser.add_argument("--quality", type=int, default=DEFAULT_QUALITY)
    args = parser.parse_args()
    build(args.source.resolve(), args.out.resolve(), args.scale, args.step, args.quality)


if __name__ == "__main__":
    main()
