#!/usr/bin/env python3
"""生成 KongGlean 的占位图标：蓝色底 + 白色 “k” + 一道金色划线（摘录的意思）。

用法：python3 Tools/generate_icon.py
依赖：pip install pillow
输出：KongGlean/Resources/Assets.xcassets/AppIcon.appiconset/*.png
以后若要与 kongfetch 统一风格，直接替换这些 PNG 即可（文件名保持不变）。
"""
import json
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "KongGlean", "Resources", "Assets.xcassets", "AppIcon.appiconset")

FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Georgia Bold.ttf",
    "/System/Library/Fonts/NewYork.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSerif-Bold.ttf",
]


def load_font(size):
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def master(size=1024):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # macOS 图标网格：内容区约为 824/1024，四周留出阴影空间
    inset = int(size * 100 / 1024)
    box = (inset, inset, size - inset, size - inset)
    radius = int((box[2] - box[0]) * 0.225)

    # 阴影
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + size * 0.012, box[2], box[3] + size * 0.012), radius, fill=(0, 0, 0, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(size * 0.015))
    img.alpha_composite(shadow)

    # 蓝色竖向渐变
    grad = Image.new("RGBA", (size, size))
    top, bottom = (64, 140, 255), (18, 72, 200)
    gd = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / (size - 1)
        gd.line([(0, y), (size, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    w = box[2] - box[0]

    # 金色划线（荧光笔）
    hl_h = int(w * 0.13)
    hl_y = box[1] + int(w * 0.66)
    d.rounded_rectangle(
        (box[0] + int(w * 0.20), hl_y, box[0] + int(w * 0.80), hl_y + hl_h),
        hl_h // 2, fill=(255, 200, 70, 235))

    # 白色 k
    font = load_font(int(w * 0.62))
    text = "k"
    l, t, r, b = d.textbbox((0, 0), text, font=font)
    x = box[0] + (w - (r - l)) / 2 - l
    y = box[1] + w * 0.43 - (b - t) / 2 - t
    d.text((x, y), text, font=font, fill=(255, 255, 255, 255))
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    big = master(1024)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            big.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    print("written to", OUT)


if __name__ == "__main__":
    main()
