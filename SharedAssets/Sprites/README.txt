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
24 帧按正弦规律驱动，一轮正好一个周期，首尾无缝。幅度可调（当前 idel 22°、pet 8°）。

**形变范围必须用 `mask_poly` 多边形锁死**，不能只靠 `gates` 这种轴对齐软边界：
尾巴根与右后腿、脖子根与后背在画面上是相邻的，矩形门拦不住，会导致「尾巴动后腿也动」「头动后背也动」。

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
# 基准图就是现有的 frame_00.png（rig 在相位 0 是恒等变换，可反复自举）
python3 tools/sprite_animate.py --src DesktopPetForMacApp/Resources/Sprites/idel --path 0 \
  --frames 24 --mode rig --out .sprite-build/out_idel \
  --rig '{"pivot":[151,126],"amp_deg":22,"gates":[["x",153,6,1]],"cycles":1,"mask_feather":4,
          "mask_poly":[[151,124],[167,128],[181,141],[188,155],[186,171],[176,178],[166,173],[159,160],[155,148],[152,138],[148,130]]}'

# 抚摸：绕脖子根部小幅点头，2s 摇两下
python3 tools/sprite_animate.py --src DesktopPetForMacApp/Resources/Sprites/pet --path 0 \
  --frames 24 --mode rig --out .sprite-build/out_pet \
  --rig '{"pivot":[85,112],"amp_deg":8,"gates":[],"cycles":2,"bob":2,"mask_feather":3,
          "mask_poly":[[66,20],[82,26],[98,37],[112,43],[130,49],[130,67],[116,79],[106,85],[98,91],[94,99],[88,104],[74,105],[62,102],[52,94],[45,80],[46,62],[52,44],[58,28]]}'
```

`--rig` 字段：`pivot` 骨根坐标 / `amp_deg` 旋转幅度 / `mask_poly` 形变范围多边形（200×200 画布坐标，必填）/ `mask_feather` 遮罩羽化半径（默认 5，越小越不溢出）/ `gates` 额外软边界（`[axis,start,ramp,dir]`，dir=+1 坐标越大权重越高）/ `bob` 竖直位移 / `cycles` 一轮内摆动次数 / `phase` 相位。
其它模式：`flow`（位移场插值）、`dissolve`、`hold`（关键姿态 + 淡化）——仅当必须用多张 AI 关键姿态时才用，质量不如 rig。

验收动作范围：把 frame_00 与最大相位帧叠成双色图看色边，或在脚本输出上算区域差：
idel 除尾巴外的区域（后腿 / 躯干 / 头）像素差必须为 0，pet 除头以外的区域（后背 / 前腿 / 尾巴）像素差必须为 0。

## AI 生成提示词
生图提示词集中在服务端 PetServer/internal/service/prompts/（pet_portrait_v1.txt 等，go:embed 编译进二进制）；
离线手动出图的美境 prompt 存档与抠图/尺寸规范见仓库 skills/meijing-pet-prompts/。
