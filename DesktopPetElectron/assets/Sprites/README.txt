# DesktopCat 精灵图资源目录

将小猫动画帧放入此目录，支持以下两种格式：

## 格式一：独立帧序列（推荐）
命名规则：{state}_{index}.png

  idle_0.png, idle_1.png, idle_2.png ...   # 待机动画（建议 4~8 帧）
  walk_0.png, walk_1.png, walk_2.png ...   # 走动动画
  jump_0.png, jump_1.png, jump_2.png ...   # 跳跃/开心动画（一次性播放）
  sleep_0.png, sleep_1.png ...             # 睡觉动画
  eat_0.png, eat_1.png ...                 # 进食动画（一次性播放）

## 格式二：单文件横向精灵图
命名规则：{state}_sheet.png

  idle_sheet.png   # 所有 idle 帧横向拼接成一张长图
  walk_sheet.png
  jump_sheet.png
  ...

## 资源要求
- 格式：PNG（带透明通道 Alpha）
- 建议单帧尺寸：128×128 pt（标准屏）或 256×256 px（@2x 视网膜屏）
- 若此目录为空，应用会显示橙色占位方块，不影响运行

## AI 生成参考提示词（Midjourney）
"A cute chibi orange cat, idle animation sprite sheet, 8 frames, transparent background, kawaii style, clean vector art, flat colors --ar 16:9 --niji 6"
