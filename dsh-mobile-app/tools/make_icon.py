# DSH Remote App 图标生成：从 assets/icon-1024.png 生成 Android 各密度图标。
# 用法: python tools/make_icon.py
# 更换图标：把新的 1024x1024 PNG 覆盖到 assets/icon-1024.png 后重新运行本脚本。
import os
from PIL import Image

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(BASE, "assets", "icon-1024.png")
RES = os.path.join(BASE, "android", "app", "src", "main", "res")

img = Image.open(SRC).convert("RGBA")
sizes = {"mipmap-mdpi": 48, "mipmap-hdpi": 72, "mipmap-xhdpi": 96, "mipmap-xxhdpi": 144, "mipmap-xxxhdpi": 192}
for folder, px in sizes.items():
    target = os.path.join(RES, folder, "ic_launcher.png")
    img.resize((px, px), Image.LANCZOS).save(target)
    print(f"{folder}/ic_launcher.png {px}px")
print("done")
