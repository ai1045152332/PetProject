#!/usr/bin/env python3
"""抠图 + 尺寸统一：连通域保留主体，软边缘，缩放到 170x170 放在 200x200 画布上。"""
import sys
from collections import deque

import numpy as np
from PIL import Image, ImageFilter

T_BG = 20.0      # 背景判定阈值（颜色距离）
T_SOFT = 55.0    # 软边缘起点：低于此距离的"主体外"像素视为地面投影/噪点，直接透明
T_EDGE = 80.0    # 软边缘终点
CANVAS = 200
PAD = 170


def background_color(im):
    h, w, _ = im.shape
    patches = [im[:20, :20], im[:20, -20:], im[-20:, :20], im[-20:, -20:]]
    px = np.concatenate([p.reshape(-1, 3) for p in patches], axis=0)
    return np.median(px, axis=0)


def flood_from_border(seed):
    """从边界出发，泛洪所有与边界连通的 seed 像素，返回连通背景掩码。"""
    h, w = seed.shape
    visited = np.zeros((h, w), dtype=bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if seed[y, x] and not visited[y, x]:
                visited[y, x] = True
                dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if seed[y, x] and not visited[y, x]:
                visited[y, x] = True
                dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and seed[ny, nx] and not visited[ny, nx]:
                visited[ny, nx] = True
                dq.append((ny, nx))
    return visited


def label_components(mask):
    """4 连通域标记，返回 [(area, coords_bool_mask)]，只保留面积较大的。"""
    h, w = mask.shape
    seen = np.zeros((h, w), dtype=bool)
    comps = []
    for y in range(h):
        row = mask[y]
        for x in np.nonzero(row & ~seen[y])[0]:
            if seen[y, x]:
                continue
            dq = deque([(y, x)])
            seen[y, x] = True
            pix = []
            while dq:
                cy, cx = dq.popleft()
                pix.append((cy, cx))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        dq.append((ny, nx))
            comps.append(pix)
    if not comps:
        return np.zeros_like(mask)
    areas = [len(p) for p in comps]
    biggest = max(areas)
    keep = np.zeros_like(mask)
    for pix, area in zip(comps, areas):
        if area >= biggest * 0.02:  # 保留主体及与其面积相当的部件，剔除小噪点
            ys = np.fromiter((p[0] for p in pix), dtype=np.int32, count=len(pix))
            xs = np.fromiter((p[1] for p in pix), dtype=np.int32, count=len(pix))
            keep[ys, xs] = True
    return keep


def process(src, dst):
    rgb = np.array(Image.open(src).convert("RGB")).astype(np.float32)
    bg = background_color(rgb)
    dist = np.sqrt(((rgb - bg) ** 2).sum(axis=2))

    bg_mask = flood_from_border(dist < T_BG)
    fg = label_components(~bg_mask)

    # 主体内：完全不透明；主体外只保留 2px 抗锯齿边带，地面投影彻底去掉
    soft = np.clip((dist - T_SOFT) / (T_EDGE - T_SOFT), 0.0, 1.0)
    fg_img = Image.fromarray((fg * 255).astype(np.uint8), "L")
    dilated = np.array(fg_img.filter(ImageFilter.MaxFilter(5))) > 127
    band = dilated & ~fg
    alpha = fg.astype(np.float32)
    alpha[band] = soft[band] * 0.9
    alpha = (alpha * 255).astype(np.uint8)

    rgba = np.dstack([rgb.astype(np.uint8), alpha])
    im = Image.fromarray(rgba, "RGBA")

    # alpha 轻微平滑，去掉锯齿
    a = im.getchannel("A").filter(ImageFilter.GaussianBlur(0.8))
    im.putalpha(a)

    bbox = im.getchannel("A").point(lambda v: 255 if v > 12 else 0).getbbox()
    if bbox:
        im = im.crop(bbox)

    # 等比缩放到 PAD 框内
    w, h = im.size
    scale = min((PAD - 8) / w, (PAD - 8) / h)
    im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(im, ((CANVAS - im.width) // 2, (CANVAS - im.height) // 2), im)
    canvas.save(dst)
    print(dst, "->", canvas.size, "subject:", im.size)


if __name__ == "__main__":
    process(sys.argv[1], sys.argv[2])
