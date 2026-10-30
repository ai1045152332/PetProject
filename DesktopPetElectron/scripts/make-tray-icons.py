#!/usr/bin/env python3
"""从 assets/MenuBarIcon.png 派生全部托盘/菜单栏图标。

单一源图：assets/MenuBarIcon.png —— 与 mac 原生版（DesktopPetForMacApp）用的是同一张资源，
所以两版菜单栏里是**同一只猫**，不需要另画一套形象。

为什么需要派生而不是直接丢原图：
  1. 原图是 RGB 不透明图（白猫 + 近黑底），mac 原生版用 NSImage + isTemplate=true，
     模板图只认 alpha，全不透明的图会被渲染成一个实心方块；
  2. 原图 360×348，直接交给 Electron Tray 会被当成 360pt 巨图；
  3. 菜单栏只有 22pt 高，整只猫（头+爪+尾巴）缩进去会糊成一团，所以 mac 版只用猫脸。
派生方式：按亮度阈值取出白猫 → 去掉细胡须 → 回填眼睛/耳内的黑洞 → 得到纯剪影。

产物：
  MenuBarTemplate.png      22×22   mac 模板图 @1x（纯黑+alpha，系统按菜单栏深浅色自动反色）
  MenuBarTemplate@2x.png   44×44   mac 模板图 @2x（Electron 按同名 @2x 自动拾取，Retina 清晰）
  WindowsTray.png          32×32   Windows 托盘 @1x（白猫+深灰描边，深浅任务栏都能看见）
  WindowsTray@2x.png       64×64   Windows 托盘 @2x

用法：python3 scripts/make-tray-icons.py [--full]
  --full  菜单栏改用完整猫身（含身体和尾巴），默认只用猫脸
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "MenuBarIcon.png"   # 与 mac 原生版共用
OUT = ROOT / "assets" / "tray"

PAD = 0.05          # 画布内边距比例
HEAD_RATIO = 0.72   # 猫脸占剪影高度的比例（耳朵尖到下巴/脖子，0.72 时脸型最接近原图）


def build_silhouette():
    """从源图提取猫的剪影：亮度阈值 → 去胡须 → 回填内部黑洞"""
    gray = Image.open(SRC).convert("RGB").convert("L")
    mask = gray.point(lambda v: 255 if v > 120 else 0)          # 白猫=255，深色底=0
    mask = mask.filter(ImageFilter.MinFilter(5))                # 腐蚀掉细胡须
    mask = mask.filter(ImageFilter.MaxFilter(5))                # 膨胀回原大小
    probe = mask.copy()
    ImageDraw.floodfill(probe, (0, 0), 128)                     # 外部背景标记为 128
    filled = probe.point(lambda v: 0 if v == 128 else 255)      # 背景归零，孔洞回填
    return filled.crop(filled.getbbox())


def fit_square(img, size, pad=PAD):
    """等比缩放并居中放进 size×size 画布"""
    inner = size * (1 - 2 * pad)
    w, h = img.size
    ratio = min(inner / w, inner / h)
    resized = img.resize((max(1, round(w * ratio)), max(1, round(h * ratio))), Image.LANCZOS)
    canvas = Image.new("L", (size, size), 0)
    canvas.paste(resized, ((size - resized.width) // 2, (size - resized.height) // 2))
    return canvas


def write_template(mask, size, name):
    """模板图：形状取剪影，RGB 全黑；macOS 按菜单栏深浅色自动反色"""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    img.putalpha(mask)
    img.save(OUT / name)
    print(f"✅ {name}  {size}×{size}  模板图（黑色剪影）")


def write_color(mask, size, name):
    """Windows 托盘：白猫填充 + 1px 深灰描边（任务栏深浅色都能看清）"""
    outline = mask.filter(ImageFilter.MaxFilter(3))                  # 外扩 1px 作描边
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    img.paste(Image.new("RGBA", (size, size), (64, 68, 74, 255)), (0, 0), outline)
    img.paste(Image.new("RGBA", (size, size), (252, 252, 255, 255)), (0, 0), mask)
    img.save(OUT / name)
    print(f"✅ {name}  {size}×{size}  白猫+1px 描边")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    silhouette = build_silhouette()
    full = "--full" in sys.argv
    face = silhouette if full else silhouette.crop(
        (0, 0, silhouette.width, int(silhouette.height * HEAD_RATIO)))
    print(f"源图 {SRC.name} {Image.open(SRC).size} → 剪影 {silhouette.size}"
          f" → 取用 {'整只猫' if full else '猫脸'} {face.size}")

    write_template(fit_square(face, 44), 44, "MenuBarTemplate@2x.png")
    write_template(fit_square(face, 22), 22, "MenuBarTemplate.png")
    write_color(fit_square(face, 64, PAD / 2), 64, "WindowsTray@2x.png")
    write_color(fit_square(face, 32, PAD / 2), 32, "WindowsTray.png")


if __name__ == "__main__":
    main()
