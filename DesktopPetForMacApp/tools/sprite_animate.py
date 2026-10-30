#!/usr/bin/env python3
"""sprite_animate.py — 把美境生成的宠物图合成为桌面宠物序列帧

两种用法：

A. rig 模式（推荐，当前 idel/pet 就是这么出的）：一张带动作的基准图 → 骨架式局部变形
   python3 tools/sprite_animate.py --src <基准图目录> --path 0 --frames 24 --mode rig \
       --rig '{"pivot":[151,126],"amp_deg":22,"cycles":1,"mask_feather":4,
               "mask_poly":[[151,124],[167,128],[181,141],[188,155],[186,171],[176,178],
                            [166,173],[159,160],[155,148],[152,138],[148,130]],
               "gates":[["x",153,6,1]]}' \
       --out <输出目录>
   绕 pivot 做旋转，权重由 mask_poly 多边形 + 羽化给出（可再乘 gates 软边界），
   正弦驱动 cycles 个周期（首尾无缝）。
   好处：画风/比例 100% 不变、动作绝对平滑、幅度与节奏都能参数化。
   注意：**只用 gates 是不够的**。尾巴根贴着右后腿、脖子根贴着后背，轴对齐的软边界
   必然连带邻肢（实测「尾巴动后腿也动」「头动后背也动」），必须用 mask_poly 把范围圈死。

B. 多关键帧模式（flow / dissolve / hold）：AI 出多张关键姿态时用，实测质量不如 rig
   flow     = 块匹配位移场插值（姿态差大时会撕裂细尾巴、把歪头拉变形）
   dissolve = 交叉淡化（出双影）
   hold     = 保持姿态 + 段末淡化（用户反馈「像在瞬移」）

公共前置步骤：
  1. clean_subject()   白底成品图 → 连通域抠图（BFS 泛洪判背景 + 最大连通域保主体 + 填洞 + 羽化）
  2. normalize()       主体等比缩到统一高度、水平居中、底边对齐 → 200×200 透明画布
  3. 变形出序列帧 + GIF 预览 + 接触表
"""
from __future__ import annotations

import argparse
import json
import math
import os
from collections import deque

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 200
SUBJECT_H = 164          # 与 idel/focus/sleep 现有素材一致
BOTTOM_Y = 181           # 主体底边所在行（现有素材基准）


# ────────────────────────────── 抠图 ──────────────────────────────
def _flood(mask: np.ndarray) -> np.ndarray:
    """从画面四周泛洪，返回「与边界连通且在 mask 内」的像素"""
    h, w = mask.shape
    filled = np.zeros((h, w), dtype=bool)
    q: deque[tuple[int, int]] = deque()
    seeds = [(0, x) for x in range(w)] + [(h - 1, x) for x in range(w)]
    seeds += [(y, 0) for y in range(h)] + [(y, w - 1) for y in range(h)]
    for y, x in seeds:
        if mask[y, x] and not filled[y, x]:
            filled[y, x] = True
            q.append((y, x))
    while q:
        y, x = q.popleft()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not filled[ny, nx]:
                filled[ny, nx] = True
                q.append((ny, nx))
    return filled


def _largest_component(mask: np.ndarray) -> np.ndarray:
    """保留最大连通域（4 邻接），滤掉毛发噪点"""
    h, w = mask.shape
    seen = np.zeros((h, w), dtype=bool)
    best_ys = np.empty(0, dtype=np.int32)
    best_xs = np.empty(0, dtype=np.int32)
    for y0 in range(h):
        for x0 in range(w):
            if not mask[y0, x0] or seen[y0, x0]:
                continue
            ys: list[int] = []
            xs: list[int] = []
            q = deque([(y0, x0)])
            seen[y0, x0] = True
            while q:
                y, x = q.popleft()
                ys.append(y)
                xs.append(x)
                for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        q.append((ny, nx))
            if len(ys) > len(best_ys):
                best_ys = np.array(ys, dtype=np.int32)
                best_xs = np.array(xs, dtype=np.int32)
    out = np.zeros((h, w), dtype=bool)
    if len(best_ys):
        out[best_ys, best_xs] = True
    return out


def _erode(alpha: np.ndarray) -> np.ndarray:
    """3×3 最小值滤波（内缩 1px，去掉贴边浅灰描边），但不吃掉本就细的边缘"""
    p = np.pad(alpha, 1, mode="edge")
    h, w = alpha.shape
    m = alpha.copy()
    for dy in (0, 1, 2):
        for dx in (0, 1, 2):
            m = np.minimum(m, p[dy:dy + h, dx:dx + w])
    return np.where(alpha > 0, m, 0).astype(np.uint8)


def clean_subject(path: str) -> Image.Image:
    raw = Image.open(path)
    if raw.mode not in ("RGBA", "LA"):
        raw = raw.convert("RGBA")
    src = raw.convert("RGB")
    if np.asarray(raw)[..., 3].min() < 250:           # 已是透明底（现有内置素材）：沿用 alpha
        alpha = np.asarray(raw)[..., 3]
    else:                                            # 美境白底成品图：泛洪 + 最大连通域 + 填洞
        rgb = np.asarray(src).astype(np.int16)
        lum = rgb.max(axis=2)
        sat = rgb.max(axis=2) - rgb.min(axis=2)
        near_white = (lum >= 236) & (sat <= 14)
        bg = _flood(near_white)                      # 与边界连通的近白 = 真背景
        fg = _largest_component(~bg)                 # 最大连通域 = 主体
        outside = _flood(~fg)                        # 主体外部的连通区域
        fg = fg | ~outside                           # 补上被主体包围的空洞
        alpha = _erode((fg * 255).astype(np.uint8))
        # 只有白底图需要羽化；已有的透明底素材本身带抗锯齿，再模糊会让 bbox 缩水
        alpha = np.asarray(Image.fromarray(alpha).filter(ImageFilter.GaussianBlur(0.6)))
    out = src.convert("RGBA")
    out.putalpha(Image.fromarray(alpha))
    bbox = Image.fromarray(((alpha > 8) * 255).astype(np.uint8)).getbbox()
    if bbox is None:
        raise SystemExit(f"抠图失败（找不到主体）：{path}")
    return out.crop(bbox)


def normalize(subject: Image.Image) -> Image.Image:
    """统一缩放到 SUBJECT_H 高、水平居中、底边压 BOTTOM_Y，贴到 200×200 透明画布"""
    w, h = subject.size
    scale = SUBJECT_H / h
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    # 已经对齐过的图（尺寸不变）不要重采样，否则反复迭代会累积模糊
    body = subject if (nw, nh) == (w, h) else subject.resize((nw, nh), Image.LANCZOS)
    if nw > CANVAS:                                  # 特宽姿态按宽度回收，防裁切
        body = body.resize((CANVAS, max(1, round(nh * CANVAS / nw))), Image.LANCZOS)
        nw, nh = body.size
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    # 画布是全新全透明的，直接拷贝即可；带 mask 贴图会把半透明边缘再做一次 alpha
    # 合成（a²/255），导致边缘变暗、bbox 逐次收缩，所以这里不能传 mask
    canvas.paste(body, ((CANVAS - nw) // 2, BOTTOM_Y + 1 - nh))
    return canvas


# ────────────────────────── 位移场（块匹配）──────────────────────────
def _premult(arr: np.ndarray) -> np.ndarray:
    rgb, alpha = arr[..., :3], arr[..., 3:4]
    return np.concatenate([rgb * alpha, alpha], axis=2)


def _feature(img: Image.Image) -> np.ndarray:
    return _premult(np.asarray(img).astype(np.float32) / 255.0)


def _box_blur(a: np.ndarray, r: int) -> np.ndarray:
    """沿前两维做 (2r+1)² 均值模糊（积分图实现）"""
    k = 2 * r + 1
    for axis in (0, 1):
        pad = [(0, 0)] * a.ndim
        pad[axis] = (r + 1, r)
        c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis)
        hi = np.take(c, range(k, c.shape[axis]), axis=axis)
        lo = np.take(c, range(0, c.shape[axis] - k), axis=axis)
        a = (hi - lo) / k
    return a


def _block_match(fa: np.ndarray, fb: np.ndarray, block: int, radius: int) -> np.ndarray:
    """单层块匹配，返回逐像素位移场 (dy, dx)"""
    h, w = fa.shape[:2]
    by, bx = h // block, w // block
    if by == 0 or bx == 0:
        return np.zeros((h, w, 2), dtype=np.float32)
    hh, ww = by * block, bx * block
    fa, fb = fa[:hh, :ww], fb[:hh, :ww]
    fbp = np.pad(fb, ((radius, radius), (radius, radius), (0, 0)), mode="edge")

    best_cost = np.full((by, bx), np.inf, dtype=np.float32)
    best = np.zeros((by, bx, 2), dtype=np.float32)
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            shifted = fbp[radius + dy:radius + dy + hh, radius + dx:radius + dx + ww]
            cost = np.abs(fa - shifted).sum(axis=2).reshape(by, block, bx, block).mean(axis=(1, 3))
            m = cost < best_cost
            best_cost = np.where(m, cost, best_cost)
            best[:, :, 0] = np.where(m, dy, best[:, :, 0])
            best[:, :, 1] = np.where(m, dx, best[:, :, 1])
    flow = np.repeat(np.repeat(best, block, axis=0), block, axis=1)
    flow = np.pad(flow, ((0, h - hh), (0, w - ww), (0, 0)), mode="edge")
    return _box_blur(flow, max(1, block // 2))


def _bilinear(src: np.ndarray, ys: np.ndarray, xs: np.ndarray) -> np.ndarray:
    h, w = src.shape[:2]
    ys = np.clip(ys, 0, h - 1)
    xs = np.clip(xs, 0, w - 1)
    y0 = np.floor(ys).astype(np.int32)
    x0 = np.floor(xs).astype(np.int32)
    y1 = np.minimum(y0 + 1, h - 1)
    x1 = np.minimum(x0 + 1, w - 1)
    wy = (ys - y0)[..., None]
    wx = (xs - x0)[..., None]
    top = src[y0, x0] * (1 - wx) + src[y0, x1] * wx
    bottom = src[y1, x0] * (1 - wx) + src[y1, x1] * wx
    return top * (1 - wy) + bottom * wy


def _warp_array(f: np.ndarray, flow: np.ndarray) -> np.ndarray:
    h, w = f.shape[:2]
    yy, xx = np.meshgrid(np.arange(h, dtype=np.float32), np.arange(w, dtype=np.float32), indexing="ij")
    return _bilinear(f, yy + flow[..., 0], xx + flow[..., 1])


def estimate_flow(a: Image.Image, b: Image.Image) -> np.ndarray:
    """粗到细块匹配：A → B 的位移场（像素）"""
    fa, fb = _feature(a), _feature(b)
    size = CANVAS // 4
    sa = _feature(a.resize((size, size), Image.BOX))
    sb = _feature(b.resize((size, size), Image.BOX))
    coarse = _block_match(sa, sb, 5, 8) * 4.0                 # 粗层覆盖 ~32px 大位移
    coarse = np.repeat(np.repeat(_box_blur(coarse, 2), 4, axis=0), 4, axis=1)[:CANVAS, :CANVAS]
    fine = _block_match(fa, _warp_array(fb, coarse), 8, 4)    # 细层补残差
    return _box_blur(coarse + fine, 2)


# ────────────────────── rig：单张素材的骨架式变形 ──────────────────────
def _smoothstep(t: np.ndarray) -> np.ndarray:
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


def _poly_weight(shape: tuple[int, int], poly: list, feather: float) -> np.ndarray:
    """多边形遮罩（0~1）。用来把形变锁死在某一块肢体上，避免相邻部位被带着动"""
    h, w = shape
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).polygon([(float(p[0]), float(p[1])) for p in poly], fill=255)
    if feather > 0:
        mask = mask.filter(ImageFilter.GaussianBlur(feather))
    return np.asarray(mask, dtype=np.float32) / 255.0


def _weight_map(shape: tuple[int, int], gates: list, poly_w: np.ndarray | None = None) -> np.ndarray:
    """按若干「软边界」生成 0~1 权重图。每个 gate = [axis, start, ramp, dir]：
    axis 取 'x'/'y'；dir=+1 表示坐标越大权重越高，-1 相反。给了 poly_w 时二者相乘"""
    h, w = shape
    yy, xx = np.meshgrid(np.arange(h, dtype=np.float32), np.arange(w, dtype=np.float32), indexing="ij")
    weight = np.ones((h, w), dtype=np.float32)
    for axis, start, ramp, direction in gates:
        coord = xx if axis == "x" else yy
        weight *= _smoothstep((coord - start) / ramp * (1 if direction >= 0 else -1))
    if poly_w is not None:
        weight *= poly_w
    return weight


def _weight_at(xx: np.ndarray, yy: np.ndarray, gates: list,
               poly_w: np.ndarray | None = None) -> np.ndarray:
    """在任意浮点坐标上求权重（供定点迭代用）"""
    weight = np.ones_like(xx, dtype=np.float32)
    for axis, start, ramp, direction in gates:
        coord = xx if axis == "x" else yy
        weight *= _smoothstep((coord - start) / ramp * (1 if direction >= 0 else -1))
    if poly_w is not None:
        weight *= _bilinear(poly_w[..., None], yy, xx)[..., 0]
    return weight


def rig_frame(img: Image.Image, pivot: tuple[float, float], angle_deg: float,
              gates: list, bob: float = 0.0, scale: float = 0.0,
              poly_w: np.ndarray | None = None) -> Image.Image:
    """绕 pivot 做软化旋转（权重由 poly_w / gates 控制），可叠加竖直位移与轻微缩放。
    权重在骨根处趋近 0、在末端趋近 1，所以接缝不会被扯断。"""
    f = _feature(img)
    h, w = f.shape[:2]
    yy, xx = np.meshgrid(np.arange(h, dtype=np.float32), np.arange(w, dtype=np.float32), indexing="ij")
    dx = xx - pivot[0]
    dy = yy - pivot[1]
    # 反向映射要做定点迭代：权重随位置变化，直接用输出像素的权重反解会折叠出「第二个尾巴」
    sx, sy = xx.copy(), yy.copy()
    for _ in range(3):
        w_iter = _weight_at(sx, sy, gates, poly_w)
        theta = np.deg2rad(angle_deg) * w_iter
        cos, sin = np.cos(theta), np.sin(theta)
        k = 1.0 + scale * w_iter
        sx = pivot[0] + (cos * dx + sin * dy) * k
        sy = pivot[1] + (-sin * dx + cos * dy) * k - bob * w_iter
    # _feature 是预乘 alpha 的，输出前必须还原成直通 alpha，否则半透明边缘会被压暗；
    # 再走 round 而不是截断，保证 angle=0 时与原图逐像素一致（可无损自举）
    out = _bilinear(f, sy, sx)
    alpha = np.clip(out[..., 3:4], 0.0, 1.0)
    rgb = np.where(alpha > 1e-4, out[..., :3] / np.maximum(alpha, 1e-4), 0.0)
    rgba = np.concatenate([np.clip(rgb, 0, 1), alpha], axis=2)
    return Image.fromarray((rgba * 255).round().astype(np.uint8))


def build_rig_sequence(img: Image.Image, total: int, cfg: dict) -> list[Image.Image]:
    """按正弦规律驱动 rig：一轮 = total 帧，首尾相接可无缝循环"""
    frames: list[Image.Image] = []
    pivot = tuple(cfg.get("pivot", (CANVAS / 2, CANVAS / 2)))
    gates = cfg.get("gates", [])
    amp = float(cfg.get("amp_deg", 0.0))
    bob = float(cfg.get("bob", 0.0))
    scale = float(cfg.get("scale", 0.0))
    cycles = float(cfg.get("cycles", 1.0))
    phase = float(cfg.get("phase", 0.0))
    poly_w = None
    if cfg.get("mask_poly"):
        poly_w = _poly_weight(img.size[::-1], cfg["mask_poly"], float(cfg.get("mask_feather", 5.0)))
    for i in range(total):
        t = i / total
        wave = math.sin(2 * math.pi * cycles * t + phase)
        frames.append(rig_frame(img, pivot, amp * wave, gates, bob=bob * wave, scale=scale * wave, poly_w=poly_w))
    return frames


# ───────────────────────────── 插值 ─────────────────────────────
def interpolate(a: Image.Image, b: Image.Image, flow: np.ndarray, t: float) -> Image.Image:
    """对称变形 + 混合：A 按 +t·flow 前进，B 按 -(1-t)·flow 回退"""
    if t <= 0.0:
        return a
    if t >= 1.0:
        return b
    wa = _warp_array(_feature(a), flow * t)
    wb = _warp_array(_feature(b), flow * -(1.0 - t))
    # alpha 三次方加权：谁的不透明轮廓更实就用谁，避免 50/50 线性混合出「双影」
    w1 = np.clip(wa[..., 3:4], 0, 1) ** 3
    w2 = np.clip(wb[..., 3:4], 0, 1) ** 3
    norm = w1 + w2 + 1e-6
    prem = (wa[..., :3] * w1 + wb[..., :3] * w2) / norm
    alpha = np.clip((wa[..., 3:4] * w1 + wb[..., 3:4] * w2) / norm, 0.0, 1.0)
    rgb = np.where(alpha > 1e-4, prem / np.maximum(alpha, 1e-4), 0.0)
    out = np.concatenate([np.clip(rgb, 0, 1), alpha], axis=2)
    return Image.fromarray((out * 255).astype(np.uint8))


def dissolve(a: Image.Image, b: Image.Image, t: float) -> Image.Image:
    """纯交叉淡化（不变形）：姿态差小时最安全，不会撕裂轮廓"""
    if t <= 0.0:
        return a
    if t >= 1.0:
        return b
    fa, fb = _feature(a), _feature(b)
    mix = fa * (1.0 - t) + fb * t
    alpha = np.clip(mix[..., 3:4], 0.0, 1.0)
    rgb = np.where(alpha > 1e-4, mix[..., :3] / np.maximum(alpha, 1e-4), 0.0)
    return Image.fromarray((np.concatenate([np.clip(rgb, 0, 1), alpha], axis=2) * 255).astype(np.uint8))


def build_sequence(keys: list[Image.Image], path: list[int], total: int,
                   mode: str = "flow", fade: int = 2) -> list[Image.Image]:
    """按关键帧路径（如 0,1,0,2,0）把 total 帧均匀分配到各段

    mode=flow    段内用位移场插值（姿态差小的连续动作）
    mode=dissolve 段内交叉淡化（姿态差中等）
    mode=hold    段内保持关键帧、仅在段末用 fade 帧淡化到下一个关键帧（姿态差大，最稳）
    """
    flows: dict[tuple[int, int], np.ndarray] = {}
    frames: list[Image.Image] = []
    seg_count = len(path) - 1
    for seg in range(seg_count):
        i, j = path[seg], path[seg + 1]
        start = int(round(seg * total / seg_count))
        end = int(round((seg + 1) * total / seg_count))
        steps = end - start
        if mode == "hold":
            hold = max(1, steps - fade)
            frames.extend([keys[i]] * hold)
            for s in range(fade):
                t = (s + 1) / (fade + 1)
                frames.append(dissolve(keys[i], keys[j], t))
        else:
            if mode == "flow" and (i, j) not in flows:
                flows[(i, j)] = estimate_flow(keys[i], keys[j])
            for s in range(steps):
                t = s / max(1, steps)
                t = t * t * (3 - 2 * t)
                frames.append(interpolate(keys[i], keys[j], flows[(i, j)], t) if mode == "flow"
                              else dissolve(keys[i], keys[j], t))
    return frames[:total]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="关键帧目录（文件名升序即索引顺序）")
    ap.add_argument("--path", default="0", help="关键帧索引路径，如 0,1,0,2,0")
    ap.add_argument("--frames", type=int, required=True, help="输出帧数")
    ap.add_argument("--out", required=True, help="输出目录")
    ap.add_argument("--mode", choices=["flow", "dissolve", "hold", "rig"], default="flow", help="合成方式")
    ap.add_argument("--rig", help="rig 模式参数 JSON：pivot/amp_deg/gates/bob/scale/cycles/phase")
    ap.add_argument("--fade", type=int, default=2, help="hold 模式每段末尾的淡化帧数")
    ap.add_argument("--keep-keys", action="store_true", help="另存归一化后的关键帧到 out/_keys")
    args = ap.parse_args()

    # 跳过本脚本自己输出的 _contact_sheet / _preview 等内部产物，否则会被当关键帧读进来
    files = sorted(f for f in os.listdir(args.src)
                   if f.lower().endswith(".png") and not f.startswith("_"))
    if args.mode == "rig":                 # rig 只用第一张基准图，没必要把整目录都归一化
        first = int(args.path.split(",")[0])
        files = [files[first]]
    keys = [normalize(clean_subject(os.path.join(args.src, f))) for f in files]
    os.makedirs(args.out, exist_ok=True)
    if args.keep_keys:
        os.makedirs(os.path.join(args.out, "_keys"), exist_ok=True)
        for f, k in zip(files, keys):
            k.save(os.path.join(args.out, "_keys", f))

    if args.mode == "rig":
        frames = build_rig_sequence(keys[0], args.frames, json.loads(args.rig))
    else:
        path = [int(v) for v in args.path.split(",")]
        frames = build_sequence(keys, path, args.frames, args.mode, args.fade)
    for i, fr in enumerate(frames):
        fr.save(os.path.join(args.out, f"frame_{i:02d}.png"))

    sheet = Image.new("RGBA", (CANVAS * len(frames), CANVAS), (235, 235, 235, 255))
    for i, fr in enumerate(frames):
        sheet.paste(fr, (i * CANVAS, 0), fr)
    sheet.save(os.path.join(args.out, "_contact_sheet.png"))

    preview = [f.resize((CANVAS * 2, CANVAS * 2), Image.LANCZOS) for f in frames]
    preview[0].save(os.path.join(args.out, "_preview.gif"), save_all=True,
                    append_images=preview[1:], duration=1000 // 12, loop=0, disposal=2)
    print(f"✅ {args.out}: {len(frames)} 帧（{len(frames) / 12:.2f}s @12fps），关键帧 {files}")


if __name__ == "__main__":
    main()
