#!/usr/bin/env python3
"""KongReview 图标生成器（与 KongFetch 同一套扁平风格：蓝色圆角方底 + 白色主体 + 蓝色细节）。

用法：
  python3 Tools/generate_icon.py            # 生成默认款到 AppIcon.appiconset
  python3 Tools/generate_icon.py --preview  # 生成三款对比图 icon-preview.png
  python3 Tools/generate_icon.py --variant b
依赖：pip install pillow
"""
import json, math, os, sys
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "KongReview", "Resources", "Assets.xcassets", "AppIcon.appiconset")

S = 4                      # 超采样倍数，最后缩小以获得平滑边缘
N = 1024 * S
BLUE = (59, 115, 239, 255)       # 与 KongFetch 取色一致
WHITE = (251, 252, 255, 255)
PALE = (205, 221, 251, 255)      # 淡蓝（后层卡片 / 高亮带）
DEFAULT = "c"


def px(v):
    return int(round(v * S))


def base():
    im = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((px(40), px(40), px(984), px(984)), radius=px(205), fill=BLUE)
    return im


def rotated_card(size, radius, fill, angle):
    w, h = size
    card = Image.new("RGBA", (px(w) + px(80), px(h) + px(80)), (0, 0, 0, 0))
    ImageDraw.Draw(card).rounded_rectangle((px(40), px(40), px(40) + px(w), px(40) + px(h)), radius=px(radius), fill=fill)
    return card.rotate(angle, resample=Image.BICUBIC, expand=True)


def paste_center(im, layer, cx, cy):
    im.alpha_composite(layer, (px(cx) - layer.width // 2, px(cy) - layer.height // 2))


def text_lines(d, x0, y0, widths, gap, thick, color, highlight=None):
    for i, w in enumerate(widths):
        y = y0 + i * gap
        if highlight is not None and i == highlight:
            d.rounded_rectangle((px(x0 - 14), px(y - 22), px(x0 + w + 14), px(y + 22)), radius=px(12), fill=PALE)
        d.rounded_rectangle((px(x0), px(y - thick / 2), px(x0 + w), px(y + thick / 2)), radius=px(thick / 2), fill=color)


def review_arrow(d, cx, cy, r, width, color, start=-60, sweep=290, head=1.0):
    """回环箭头（↻，顺时针）：从 start 度起画 sweep 度的粗圆弧，终点接一个三角箭头。
    角度按 PIL 约定：0° 在三点钟方向，顺时针增加。"""
    end = start + sweep
    box = (px(cx - r), px(cy - r), px(cx + r), px(cy + r))
    d.arc(box, start, end, fill=color, width=px(width))
    mid = r - width / 2
    # 起点圆头
    a0 = math.radians(start)
    sx, sy = cx + mid * math.cos(a0), cy + mid * math.sin(a0)
    d.ellipse((px(sx - width / 2), px(sy - width / 2), px(sx + width / 2), px(sy + width / 2)), fill=color)
    # 终点箭头：底边垂直于切线、中心落在弧线上，尖端沿顺时针切线方向伸出
    a = math.radians(end)
    ex, ey = cx + mid * math.cos(a), cy + mid * math.sin(a)
    tx, ty = -math.sin(a), math.cos(a)
    nx, ny = math.cos(a), math.sin(a)
    half = width * 1.05 * head
    length = width * 1.35 * head
    p1 = (ex + nx * half, ey + ny * half)
    p2 = (ex - nx * half, ey - ny * half)
    tip = (ex + tx * length, ey + ty * length)
    d.polygon([(px(x), px(y)) for x, y in (p1, tip, p2)], fill=color)


def variant_a():
    """摘录卡片叠放，卡片右下角一个回环箭头（与 KongFetch“文件夹 + 放大镜”同构）"""
    im = base()
    paste_center(im, rotated_card((480, 580), 56, PALE, 8), 478, 500)
    paste_center(im, rotated_card((480, 580), 56, WHITE, -3), 500, 518)
    lines = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    text_lines(ld, 330, 352, [320, 340, 260], 70, 24, BLUE, highlight=1)
    lines = lines.rotate(3, resample=Image.BICUBIC, center=(px(500), px(518)))
    im.alpha_composite(lines)
    d = ImageDraw.Draw(im)
    review_arrow(d, 560, 630, 112, 40, BLUE, start=-40, sweep=280)
    return im


def variant_b():
    """打开的书 + 高亮带 + 回环箭头"""
    im = base()
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((px(196), px(290), px(506), px(720)), radius=px(44), fill=WHITE)
    d.rounded_rectangle((px(518), px(290), px(828), px(720)), radius=px(44), fill=WHITE)
    text_lines(d, 246, 380, [210, 180, 210, 150], 66, 22, BLUE, highlight=1)
    text_lines(d, 568, 380, [210, 160], 66, 22, BLUE)
    review_arrow(d, 672, 594, 84, 34, BLUE, start=-40, sweep=280)
    return im


def quad(p0, c, p1, n=48):
    """二次贝塞尔曲线取样"""
    pts = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * c[0] + t ** 2 * p1[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * c[1] + t ** 2 * p1[1]
        pts.append((x, y))
    return pts


def open_book(d, fill, dy=0, left=176, right=848, top=262, bottom=772, spine_dip=46, corner=40):
    """打开的书的轮廓：左右两页，上下边缘向书脊处下凹，外侧圆角"""
    cx = (left + right) / 2
    pts = []
    # 左页：书脊顶 → 左上角 → 左下角 → 书脊底
    pts += quad((cx, top + spine_dip + dy), (left + 170, top - 18 + dy), (left + corner, top + dy))
    pts += quad((left + corner, top + dy), (left, top + dy), (left, top + corner + dy), 12)[1:]
    pts += [(left, bottom - corner + dy)]
    pts += quad((left, bottom - corner + dy), (left, bottom + dy), (left + corner, bottom + dy), 12)[1:]
    pts += quad((left + corner, bottom + dy), (left + 170, bottom - 18 + dy), (cx, bottom + spine_dip + dy))[1:]
    # 右页：书脊底 → 右下角 → 右上角 → 书脊顶（镜像）
    mirror = [(2 * cx - x, y) for x, y in reversed(pts[1:-1])]
    poly = pts + mirror
    d.polygon([(px(x), px(y)) for x, y in poly], fill=fill)


def variant_c():
    """书的轮廓上，回环箭头环绕小写 k（保留 kong 系列的 k 元素）"""
    im = base()
    d = ImageDraw.Draw(im)
    open_book(d, PALE, dy=26)          # 下面一层淡蓝：书页的厚度
    open_book(d, WHITE)
    cy = 512
    review_arrow(d, 512, cy, 214, 46, BLUE, start=-50, sweep=290, head=1.0)
    # 小写 k：竖笔 + 两笔斜画
    w = 44
    oy = cy - 512
    d.rounded_rectangle((px(448), px(408 + oy), px(448 + w), px(626 + oy)), radius=px(w / 2), fill=BLUE)
    # 两笔斜画都从竖笔中线起笔，接口处不留缺口
    d.line([(px(470), px(574 + oy)), (px(576), px(478 + oy))], fill=BLUE, width=px(w))
    d.line([(px(470), px(548 + oy)), (px(584), px(622 + oy))], fill=BLUE, width=px(w))
    for (x, y) in ((576, 478 + oy), (584, 622 + oy)):
        d.ellipse((px(x - w / 2), px(y - w / 2), px(x + w / 2), px(y + w / 2)), fill=BLUE)
    return im



CLEAR = (0, 0, 0, 0)
INK = (0, 0, 0, 255)


def menubar_template():
    """菜单栏用的单色模板图：黑色书形，回环箭头与 k 镂空（macOS 按模板图自动适配深浅色菜单栏）。
    线条比 App 图标加粗，以便缩到 18 点仍清楚。"""
    im = Image.new("RGBA", (N, N), CLEAR)
    d = ImageDraw.Draw(im)
    open_book(d, INK, left=96, right=928, top=212, bottom=812, spine_dip=50, corner=56)
    cy = 512
    review_arrow(d, 512, cy, 262, 60, CLEAR, start=-50, sweep=290, head=1.2)
    w = 64
    d.rounded_rectangle((px(444), px(402), px(444 + w), px(628)), radius=px(w / 2), fill=CLEAR)
    d.line([(px(476), px(574)), (px(578), px(476))], fill=CLEAR, width=px(w))
    d.line([(px(476), px(546)), (px(586), px(624))], fill=CLEAR, width=px(w))
    for (x, y) in ((578, 476), (586, 624)):
        d.ellipse((px(x - w / 2), px(y - w / 2), px(x + w / 2), px(y + w / 2)), fill=CLEAR)
    bbox = im.getbbox()
    im = im.crop(bbox)
    side = max(im.width, im.height)
    sq = Image.new("RGBA", (side, side), CLEAR)
    sq.alpha_composite(im, ((side - im.width) // 2, (side - im.height) // 2))
    return sq


def write_menubar(out_dir):
    img = menubar_template()
    paths = []
    for scale in (1, 2):
        size = 18 * scale
        path = os.path.join(out_dir, "menubar@%dx.png" % scale)
        img.resize((size, size), Image.LANCZOS).save(path)
        paths.append(path)
    return paths

VARIANTS = {"a": variant_a, "b": variant_b, "c": variant_c}


def render(variant):
    return VARIANTS[variant]().resize((1024, 1024), Image.LANCZOS)


def write_iconset(img):
    os.makedirs(OUT, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            n = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            img.resize((n, n), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)


def preview(path):
    tiles = [render(k) for k in "abc"]
    sheet = Image.new("RGBA", (3 * 560 + 40, 640), (246, 246, 248, 255))
    d = ImageDraw.Draw(sheet)
    for i, t in enumerate(tiles):
        x = 40 + i * 560
        sheet.alpha_composite(t.resize((480, 480), Image.LANCZOS), (x, 40))
        # 小尺寸效果（Dock 小图 / 访达列表）
        for j, s in enumerate((64, 32, 16)):
            sheet.alpha_composite(t.resize((s, s), Image.LANCZOS), (x + 40 + j * 90, 560 - s // 2))
        d.text((x + 400, 548), "ABC"[i], fill=(60, 60, 60, 255))
    sheet.save(path)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--preview" in args:
        out = args[args.index("--preview") + 1] if len(args) > args.index("--preview") + 1 else os.path.join(ROOT, "icon-preview.png")
        preview(out)
        print("preview:", out)
    else:
        if "--menubar" in args:
            out = args[args.index("--menubar") + 1]
            print("menubar icons:", write_menubar(out))
            sys.exit(0)
        v = args[args.index("--variant") + 1] if "--variant" in args else DEFAULT
        write_iconset(render(v))
        print("icon variant", v, "written to", OUT)
