#!/usr/bin/env python3
"""美境宠物素材后处理：纯色/黑底抠图 + 缩放到统一画布。

用法:
    python3 cut_sprite.py <输入图> <输出png> [--canvas 200] [--height 114]
                          [--align left|center] [--bg 26]

流程(与 SKILL.md「关键约束」一致):
    1. 降采样到 <=600px 宽加速纯 Python 泛洪(远大于最终尺寸, 不影响质量)
    2. 从四边对「近黑」像素做 8 邻域泛洪标记背景 —— 阈值取低以免吃掉深色毛发
    3. 前景保留最大连通域 —— 顺带甩掉角落水印等孤立小块
    4. 裁到主体包围盒, 等比缩放到目标主体高度
    5. 落到透明画布: hide 用 --align left(贴左边缘), 其余四态用 --align center(居中)

约定尺寸(见 references/prompts.md):
    hide  躲藏:  --align left  --height 114
    其余 4 态:   --align center --height 162
"""
import argparse
import sys
from collections import deque

from PIL import Image


def flood_background(px, W, H, thr):
    """从四边泛洪标记与边界连通的近黑背景, 返回 bytearray(1=背景)。"""
    is_bg = bytearray(W * H)

    def near_black(x, y):
        p = px[x, y]
        return p[0] < thr and p[1] < thr and p[2] < thr

    q = deque()
    for x in range(W):
        for y in (0, H - 1):
            if near_black(x, y) and not is_bg[y * W + x]:
                is_bg[y * W + x] = 1
                q.append((x, y))
    for y in range(H):
        for x in (0, W - 1):
            if near_black(x, y) and not is_bg[y * W + x]:
                is_bg[y * W + x] = 1
                q.append((x, y))
    while q:
        x, y = q.popleft()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                nx, ny = x + dx, y + dy
                if 0 <= nx < W and 0 <= ny < H and not is_bg[ny * W + nx] and near_black(nx, ny):
                    is_bg[ny * W + nx] = 1
                    q.append((nx, ny))
    return is_bg


def largest_component(is_bg, W, H):
    """在前景(非背景)里找最大 8 邻域连通域, 返回坐标列表。"""
    seen = bytearray(W * H)
    best = []
    for i in range(W * H):
        if is_bg[i] or seen[i]:
            continue
        sx, sy = i % W, i // W
        comp = [(sx, sy)]
        seen[i] = 1
        qq = deque([(sx, sy)])
        while qq:
            x, y = qq.popleft()
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H:
                        j = ny * W + nx
                        if not is_bg[j] and not seen[j]:
                            seen[j] = 1
                            comp.append((nx, ny))
                            qq.append((nx, ny))
        if len(comp) > len(best):
            best = comp
    return best


def main():
    ap = argparse.ArgumentParser(description="宠物素材抠图与缩放")
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--canvas", type=int, default=200, help="输出正方形画布边长(默认 200)")
    ap.add_argument("--height", type=int, default=114, help="主体目标高度像素(hide 114 / 其余 162)")
    ap.add_argument("--align", choices=["left", "center"], default="left", help="hide 用 left, 其余用 center")
    ap.add_argument("--bg", type=int, default=26, help="近黑背景阈值(三通道都小于此值), 越小越保守")
    args = ap.parse_args()

    im = Image.open(args.src).convert("RGB")
    if im.width > 600:
        r = 600 / im.width
        im = im.resize((600, int(im.height * r)), Image.LANCZOS)
    W, H = im.size
    px = im.load()

    is_bg = flood_background(px, W, H, args.bg)
    comp = largest_component(is_bg, W, H)
    if not comp:
        print("未找到前景主体, 请调低 --bg 或检查背景是否纯色", file=sys.stderr)
        sys.exit(1)

    mask = Image.new("L", (W, H), 0)
    mp = mask.load()
    for (x, y) in comp:
        mp[x, y] = 255
    rgba = im.convert("RGBA")
    rgba.putalpha(mask)

    cat = rgba.crop(mask.getbbox())
    scale = args.height / cat.height
    nw, nh = max(1, round(cat.width * scale)), args.height
    cat = cat.resize((nw, nh), Image.LANCZOS)

    canvas = Image.new("RGBA", (args.canvas, args.canvas), (0, 0, 0, 0))
    x = 0 if args.align == "left" else (args.canvas - nw) // 2
    y = (args.canvas - nh) // 2
    canvas.paste(cat, (x, y), cat)
    canvas.save(args.out)
    print(f"saved {args.out}  subject {nw}x{nh}  align={args.align}  canvas={args.canvas}", file=sys.stderr)


if __name__ == "__main__":
    main()
