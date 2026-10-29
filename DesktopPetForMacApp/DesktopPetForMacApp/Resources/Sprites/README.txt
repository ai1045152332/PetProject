# 宠物精灵图资源目录

宠物各状态的姿态图放在此目录，加载器（SpriteSheet.swift）支持两种布局：

## 布局一：按状态分子目录（推荐）
每个状态一个子文件夹，帧文件按文件名升序播放：

  Sprites/focus/frame_00.png, frame_01.png ...   # 专注
  Sprites/idel/frame_00.png, ...                 # 休闲
  Sprites/sleep/frame_00.png, ...                # 睡觉
  Sprites/pet/frame_00.png, ...                  # 抚摸
  Sprites/hide/frame_00.png                      # 躲藏（贴屏幕侧边，只探出脑袋、一点前胸和一只小爪）

## 布局二：扁平命名（SPM 兼容）
所有帧平铺在本目录，用状态名前缀区分：

  focus_0.png, focus_1.png, ...
  idel_0.png, ...

## 五种状态
focus（专注）/ idel（休闲）/ sleep（睡觉）/ pet（抚摸）/ hide（躲藏）。
注：原「提醒 warn」状态已合并进专注，不再生成；喝水提醒复用专注形象。

## 帧数现状
- idel（休闲）：24 帧真动画（摇尾巴），12fps 循环，一轮 2.0s
- pet（抚摸）：24 帧真动画（轻微左右蹭头），12fps 一次性播放，一轮 2.0s
- focus / sleep：仍是单张基准图复制成 8 帧（动作由渲染层呼吸缩放实现），历史内置素材
- hide：单帧

动画的做法是 **单张 AI 基准图 + `tools/sprite_animate.py --mode rig` 骨架式变形**：
绕尾巴根部 / 脖子根部做带权重衰减的旋转，权重从骨根到末端平滑过渡，所以接缝不会扯断。
24 帧按正弦规律驱动，一轮正好一个周期，首尾无缝。幅度可调（当前 idel 20°、pet 8°，见脚本参数）。

实测过、并且**不要再用**的两种做法：
1. AI 逐帧出图——帧间主体尺寸差 25%，统一尺寸后近似静止；
2. AI 关键姿态 + 硬切/淡化——姿态差大时看起来像瞬移；光流位移场插值又会把细尾巴扇成一片、把歪头拉变形。

## 资源要求
- 格式：PNG（带透明通道 Alpha），背景真正透明
- 主体悬浮，脚下不要地面阴影、不要投影（投影与爪子连通会被抠图判成主体）
- 建议单帧尺寸：200×200 透明画布，主体等比缩放居中（hide 状态主体左边缘对齐画布左边、不居中）
- **同一状态的所有帧必须尺寸相同、主体高度相同、底边对齐**，否则播放时会上下跳
- 若某状态目录为空，应用会显示橙色占位方块，不影响运行

## 重新生成动画

```bash
# 只需一张基准图（--src 目录里文件名升序，rig 模式只用第 1 张）
python3 tools/sprite_animate.py --src .sprite-build/keys_idel2 --path 0 --frames 24 --mode rig \
  --rig '{"pivot":[151,126],"amp_deg":20,"gates":[["x",140,18,1],["y",100,16,1]],"cycles":1}' \
  --out .sprite-build/out_idel

# 抚摸：绕脖子根部小幅点头，2s 摇两下
python3 tools/sprite_animate.py --src .sprite-build/keys_pet_base --path 0 --frames 24 --mode rig \
  --rig '{"pivot":[85,112],"amp_deg":8,"gates":[["y",112,16,-1]],"cycles":2,"bob":2}' \
  --out .sprite-build/out_pet
```

`--rig` 字段：`pivot` 骨根坐标 / `amp_deg` 旋转幅度 / `gates` 软边界（`[axis,start,ramp,dir]`，dir=+1 坐标越大权重越高）/ `bob` 竖直位移 / `cycles` 一轮内摆动次数 / `phase` 相位。
其它模式：`flow`（位移场插值）、`dissolve`、`hold`（关键姿态 + 淡化）——仅当必须用多张 AI 关键姿态时才用，质量不如 rig。

## AI 生成提示词
生图提示词集中在服务端 PetServer/internal/service/prompts/（pet_portrait_v1.txt 等，go:embed 编译进二进制）；
离线手动出图的美境 prompt 存档与抠图/尺寸规范见仓库 skills/meijing-pet-prompts/。
