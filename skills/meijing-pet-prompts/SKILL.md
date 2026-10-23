---
name: meijing-pet-prompts
description: 用美境 AI 设计师（gpt-image-2.5-sunburst-vision）为桌面宠物生成 4 状态单帧姿态图（idel/sleep/pet/focus，原 warn 已合并进 focus）的 prompt 模板与踩坑要点。当用户要求换宠物形象、新增状态、重生成素材时使用。生成后需手动处理抠图与尺寸统一到 200×200 透明画布。
metadata:
  short-description: Meijing AI prompts for pet sprite generation
---

# 美境宠物姿态素材 Prompt 存档

为 `DesktopPetForMacApp` 生成 4 个状态的宠物姿态图（提醒 warn 已合并进专注，不再生成）。**每状态只做 1 帧静态图**，呼吸、状态切换等动画交给 App 渲染层实现，**不再让 AI 逐帧生成多帧动画**。

## 核心策略

- 平台：美境 AI 设计师（内网），模型 `gpt-image-2.5-sunburst-vision`
- 身份锚点：真实猫咪照片（银渐层英短）作为参考图；S3 URL 24h 过期需重传
- 输出：5 张 PNG → 手动抠图缩放 → 落到 `Sprites/{state}/frame_00.png`
- `SpriteSheet` 单帧加载即可，呼吸由渲染层缩放实现

## 使用步骤

1. 打开对应状态的 prompt（见 [references/prompts.md](references/prompts.md) 的「一、各状态基准图」）
2. 参考图用 `[@image:#1]` 占位符插入开头，末尾附 `For Image #1: URL: <S3 URL>`
3. `generate.py "<组装后的 prompt>"` 提交 1 张
4. `poll.py` 轮询取图
5. 成品图手动抠图并缩放到 200×200 透明画布居中（参考约束 4、5）

## 通用后缀（保持一致才能五状态风格统一）

```
3头身Q版卡通可爱风格，干净浅色纯色背景，纯白背景，猫身悬浮在背景中，
脚下不要地面阴影、不要投影、不要影子，画面中只有这一只猫，无文字无水印
```

## 关键约束（易踩坑）

1. **背景必须显式写「不要地面阴影」**：模型默认会给猫加一块浅灰投影，抠图时投影与爪子连通会被判成主体，深色壁纸下明显发灰；阈值/连通域去不掉，**只能靠 prompt 从源头规避**。
2. **抚摸态必须显式写「不要出现人的手」**：否则模型会画一只手在猫头上。
3. **不要做多帧**：曾实测 8 帧 bbox 640~794（约 25% 差异），统一尺寸后帧间无动作差异≈静止，白白增加成本。单帧 + 渲染层缩放才是正解。
4. **抠图必须连通域**：仅靠「亮度>235 去背景」会把耳朵尖/尾巴当噪点剔除；用 BFS 从边界泛洪判背景 + 最大连通域保主体。
5. **尺寸统一**：成图 1024×1024 → 抠图 → 等比缩到 170×170 → 贴到 200×200 透明画布；实测五状态主体高度统一为 162px，切换不跳动。

## 与其他 skill 的关系

- 素材放到位后如何打包 → `deploy-cute-pet`

## 完整 prompt 存档

四个状态的组装好 prompt 全文见 [references/prompts.md](references/prompts.md)。
