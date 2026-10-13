# macOS 菜单栏宠物动画素材生成技术方案

## 摘要

建议采用**完全本地优先、云端可选**的架构：默认离线处理用户照片，只在用户显式选择“高质量”并确认隐私条款后，才允许把照片发送到受控云端服务。菜单栏真正的展示区不是自由画布，`NSStatusItem` 的 `squareLength` 等于菜单栏厚度，`variableLength` 才允许按内容扩宽，因此首版不应把多帧宠物持续塞进状态项；正确产品形态是状态栏常驻图标，点击后在独立窗口或扩展界面中显示宠物，状态栏图标本身只做少量静帧或极低频状态变化[1]。最小可用方案使用 SDXL 类基模 + 草图/深度 ControlNet + 预制宠物骨架模板，生成 768×768、每状态 8 帧、12 fps 的透明 APNG；进阶方案以宠物身份参考和受控姿态/视频驱动为主，配合“生成—评价—修补—重生成”闭环，输出 1024 或 1152 基准帧并降采样到 160–256 px 显示。Apple 的 Core ML Stable Diffusion 项目已提供 Swift 包、Core ML 转换、ControlNet 转换、2/4/6/8-bit 权重量化及 U-Net 分块能力，足以作为本地推理底座[2]；但独立开发者不应把某一代模型或某一具体推理速度写死，所有版本、权重与性能都必须在目标 macOS、芯片和量化配置下实测。

## 一、产品边界先定：菜单栏只是入口，动画主体不应挤在状态项里

**菜单栏空间是系统公共资源，长期动效和多帧序列应放到独立展示层。** Apple 的 `NSStatusItem` 提供 `squareLength`（与菜单栏厚度相等）和 `variableLength`（按内容宽度变化）[1]。这意味着状态项适合显示正方形图标、短标签或少数状态指示，不适合承载四足动物走路循环。推荐结构是：`NSStatusItem` 固定图标负责常驻入口、生成状态、空闲/睡觉/走路语义和菜单；用户点击后由独立无边框 `NSWindow` 或 `expandedInterfaceDelegate` 管理的扩展界面显示宠物；如果未来要求“一直贴在菜单栏附近走动”，走路循环也应放在紧邻状态项的弹出视图，而非持续改动系统菜单项。

建议默认逻辑如下：

| 场景 | 菜单栏状态项 | 扩展界面/独立窗口 |
|---|---|---|
| 空闲 idle | 1–3 张呼吸循环静帧，或极小 APNG | 8 帧循环，缓慢呼吸/眨眼 |
| 睡觉 sleep | 闭眼静帧，可能带 Z 计数 | 8 帧呼吸、耳朵/尾巴微动 |
| 走路 walk | 不改变状态项，避免干扰 | 8 帧循环，沿窗口底部平移 |
| 生成中 | 进度指示，可暂停/取消 | 进度、预览、取消按钮 |
| 错误 | 明确错误图标，菜单可重试 | 原因、重试、改用云方案 |

状态项中的宠物形象不要超过状态项高度，应以 2×/3× 的 `@2x/@3x` 资源设计；即使最终显示仅约 22 pt，渲染资产也应准备 44、66 px 及内容适配版本。动画窗口的可视内容建议默认 96–160 pt，最高提供 256 pt 选项，并由用户选择“菜单栏陪伴”或“桌面宠物”。前者强调极低占用，后者才允许较大动画。Apple 要求菜单栏设计保持稳定、可识别、不抢占空间[14]，因此不要让宠物在用户未明确展开时自动放大、跨越屏幕或抢占点击。

**完全本地优先不是营销口号，而是用户照片处理的默认安全边界。** 照片是敏感个人数据，App 应默认只在设备内处理；生成的宠物资源保存在 App 沙盒容器中，上传照片不离开设备，也不关联账户。联网只用于模型下载、可选云端生成、崩溃诊断（可关闭）和遥测（先显示用途、采样开关）。App Sandbox 通过授权限制文件、网络与硬件访问；沙盒 App 的容器是其可读写区域，外置命令行辅助工具也必须继承沙盒配置[3]。因此推荐默认沙盒、默认无网络、按用户选择打开网络出口，而不是一开始就申请 Photos 全库访问。

## 二、选型结论：本地 Stable Diffusion/ControlNet 负责“造素材”，视频模型只负责进阶质量档

**最小可用方案优先选 SDXL 类基模，不建议把完整 FLUX 管线作为首版唯一本地路径。** SDXL 原生基准训练分辨率为 1024×1024，总像素约 1,048,576，并在不超过该像素总量的多宽高比上微调[4]；这使其更适合生成含毛发、斑纹、耳朵、尾巴等细节的身份基准帧。FLUX 类模型生成质量、提示词理解和生态在持续变化，2026 年具体变体、许可证、量化兼容性和 Apple Silicon 本地运行时都必须以当前模型卡和推理工具实测为准，故本报告不锁定其“事实版本”。若团队后续采用 FLUX 系列，应把它当作可插拔生成后端，通过统一 `ImageGenerator` 协议隔离提示词、分辨率、ControlNet/条件图、采样器与后处理差异。

**姿势控制首版应“预制模板优先”，模型生成负责风格和细节，而不是让模型自由解释“走路”。** 传统 ControlNet 可使用边缘、深度、分割、姿态等额外条件约束扩散模型；Apple 的 Core ML 项目支持 `--convert-controlnet`，并提供 `--unet-support-controlnet` 转换路径[2]。但现成 OpenPose 模型主要面向人体骨架，宠物四足结构、尾巴、翅膀、鳍和坐姿并不通用。可靠做法是建立物种无关的四足宠物逻辑骨架：肩/髋、肘/膝、腕/踝、足、颈根、头、尾根/尾中/尾尖；再为每个状态预制 8 个骨架关键帧，生成渲染用骨架图、深度图、法向图或边缘图。基模负责“长成哪只宠物”，骨架条件负责“摆成什么动作”。

**通用人物分割 API 不能单独承担宠物抠图，必须叠加热区与形态学校正。** Vision 的 `VNGeneratePersonSegmentationRequest` 面向“检测到的人”，质量可选 `.fast/.balanced/.accurate`，输出 8-bit 单通道 mask[5]；它可能在猫狗照片上偶然有效，却不是宠物主体保证。进阶应组合：用户选择主体、显著性、边缘感知 mask、显著性图、脸部/眼部检测、颜色与纹理亲和传播、连通域和闭合轮廓。最终 mask 再经小半径高斯模糊、锐化 alpha 边缘、去除小孔洞和前景膨胀/收缩，输出预乘透明 PNG。没有置信度或显著性证据时，必须回退到“原图 + 编辑界面”，不能把错切背景伪装成成功。

**序列帧生成优于直接生成整段视频作为首版资产方案，但高质量档必须引入视频/图像动画模型。** 逐帧独立调用扩散模型成本最低，却最容易身份漂移、毛发闪烁、爪数变化；图像动画模型如 LivePortrait 通过源外观和驱动信号产生连续动作，官方称动物微调后可由人驱动猫、狗、熊猫，RTX 4090 上给出 12.8 ms/帧数据[6]。但该数据来自特定 GPU，不代表 M 系列本地性能；而且 LivePortrait 面向头部/面部驱动，不能自然表达全身躺卧、四足行走和尾巴摆动。故最佳组合是：全身关键姿态用 SDXL+ControlNet 生成基准帧，头部/眨眼/张嘴等微表情用视频或肖像动画模型驱动，再把局部结果按固定锚点合成回全身帧。

## 三、两档方案参数：先保证可交付，再追求更像“同一个生命体”

**最小可用方案以“确定性强”为核心，而不是追求每次都像电影级渲染。** 输入限制为 1–3 张照片：第 1 张必须是正面或侧面清晰全身照；第 2 张补充背面/另一侧和面部；第 3 张仅在有清晰斑纹、项圈、毛色边界时使用。每张限制最大边长 2048 px，自动按长边降采样、Exif 方向校正、裁剪无效边界，随后运行主体选择。建议输入评分：单只主体置信度、对焦清晰度、光照均匀性、全身可见度、面部可见性、背景简洁度；只有“主体明确 + 可抠图 + 至少一张可用”才进入生成。

| 参数 | 最小可用方案 | 高质量进阶方案 |
|---|---|---|
| 生成基准帧 | 768×768；必要时 832×832 | 1024×1024；必要时 896×1152/1152×896 |
| 状态资源显示 | 96–160 pt，可选最大 256 pt | 160–256 pt，支持 Retina 资产 |
| 每状态帧数 | 8 帧 | 12 帧 idle；8–12 帧 sleep；12 帧 walk |
| 帧率 | 12 fps，idle/sleep 可 8 fps | 12 fps，关键微表情 24 fps 局部合成 |
| 走路步循环 | 8 帧对称循环，或 12 帧含抬腿 | 12–16 帧，带尾巴/耳朵相位差 |
| 基模 | SDXL 类；可选 FLUX 类作 A/B 后端 | 身份参考模型 + SDXL/FLUX 类可插拔后端 |
| 姿势条件 | 手绘骨架、深度、草图 | 逻辑骨架 + 深度/边缘/视频驱动 |
| 抠图 | 用户主体选择 + 传统分割 | 主体模型 + 显著性 + 边缘精修 |
| 一致性策略 | 统一身份提示词、基准帧、骨架、色彩卡 | 身份参考 + 跨帧 attention/视频驱动 + 自动评分重生成 |
| 输出容器 | APNG，状态项另存 PNG | APNG/WebP + PNG 母版 + JSON 元数据 |

基准生成可以低于最终菜单栏显示尺寸，但 **768 px 是为保留斑纹、毛边和四肢细节而设，不是最终贴图尺寸**。例如以 768 px 生成，生成后再统一缩放到 128、160、200、256 pt 的 2×/3×资源，能避免先缩小再放大造成的模糊。若设备只能安全运行 512 px 级模型，可生成 640×640 或 704×704，再在预览界面明确标注“低资源模式可能损失毛发细节”，不能静默把低分辨率资产当作高画质交付。

**帧数和帧率应按动作语义设计，而非三态共用一套数字。** idle 用 8 帧呼吸/眨眼已足以循环，8 fps 能降低功耗；sleep 只需 4–8 帧，甚至可以 2 帧缓慢交叉淡化；walk 建议 8 或 12 帧，其中 8 帧适合“小步快走”，12 帧更适合“自然四节拍步态”。每帧显示时间应完全对齐 12 fps，即 83.33 ms；不应依赖 SwiftUI 动画的默认缓动，否则循环会呼吸或漂移。

## 四、推荐技术栈：AppKit 主窗口、Swift 业务、Core ML 主推理、Python/ONNX 仅做离线转换或辅助

**客户端应以 AppKit/Swift 为主，而不是 SwiftUI-only。** `NSStatusItem`、独立无边框窗口、拖拽、鼠标穿透、菜单和生命周期更适合 AppKit 精确控制；SwiftUI 负责配置面板、上传预览、生成进度和设置界面，通过 `NSHostingView` 或 `NSHostingMenu` 嵌入。状态项显示建议用 `NSImage`/`CALayer`；展开后的动画窗口优先预解码帧，通过 `CADisplayLink` 按目标时间推进。Core Animation 官方建议用 `targetTimestamp` 驱动动画和物理，并处理回调超时后的恢复，因此帧播放器应维护累计误差，而不是简单 `Task.sleep`[7]。

本地推理推荐优先级是：① 原生 Core ML Stable Diffusion Swift 包；② Core ML 模型通过 `mlpackage/mlmodelc` 加载；③ 确需 ONNX 算子或现有 PyTorch 模型时，使用 ONNX Runtime 的 CoreML EP；④ Python 仅用于构建期转换和本地实验，不随发行包常驻。Apple 的 Core ML Stable Diffusion 明确包含 Swift 包和 Core ML 模型转换工具，官方示例覆盖 M1 MacBook Pro、M2 MacBook Air 等[2]。其 M1 Max 官方示例端到端耗时 46 秒、0.46 iter/s，但这是历史模型与环境的参考数据，不能外推到 SDXL、FLUX、量化或 2026 年系统，产品必须自建基准。

ONNX Runtime 的 CoreML EP 支持 macOS，可将模型创建为 MLProgram（Core ML 5 / macOS 12+），并选择 `CPUOnly/CPUAndNeuralEngine/CPUAndGPU/ALL`、限制静态输入、设置编译缓存目录[8]。这对复用社区模型很实用，但存在算子不支持和子图回退风险，所以要把 fallback 视为显式测试项：转换完成后检查每个节点所在 EP，跑固定提示词与骨架，比较 CoreML EP、CPU EP 与参考 PyTorch 输出；只记录平均 PSNR/SSIM 和视觉缺陷，不应只比较延迟。

Core ML 会动态把图分区到 Neural Engine、GPU 和 CPU，NE/GPU 常用 float16、CPU 可用 float32[9]。默认 `All` 对多数模型合理，但对质量要求敏感的生成模型应先测三档。若某代 Mac 上出现颜色漂移或骨架失配，再比较 `cpuAndGPU`、降低精度配置或锁定输入形状；不要让 App 在用户无感知时静默降级到 CPU。coremltools 支持转换时设置 `compute_precision=FLOAT32`；是否采用要在 3 张以上宠物测试集上验证，因为更高精度可能换来更低吞吐[9]。

## 五、生成流水线：一张身份卡、三个动作模板、四层质量门

**流水线必须围绕“身份锚点”组织，而不是把三张照片随机塞给模型。** 第一阶段是摄入：限制 1–3 张、总大小与像素、拒绝明显多主体、读取方向和色彩空间。第二阶段是身份建立：主体提取、关键点/显著区域、毛发与斑纹采样、主导色和轮廊卡，生成 `reference.json` 与 `identity.png`。第三阶段是动作规划：从 `assets/poses` 选择 idle/sleep/walk 模板，把身份锚点投影到骨架。第四阶段是基准帧生成：以身份图、条件图和状态提示词生成关键帧；walk 必须成对生成“左前腿/右前腿”起始和镜像帧，确保循环闭合。

```
Photos
 -> IntakeValidator
 -> SubjectPicker / Segmenter
 -> IdentityBuilder
 -> PoseTemplateEngine
 -> ConditionRenderer(sketch/depth/normal/edge)
 -> ImageGenerator
 -> FrameConsistencyChecker
 -> MattingRefiner
 -> AssetPackager
 -> PlayerPreviewer
```

建议的身份提示词不要硬编码宠物品种，而应抽取结构化属性：

```json
{
  "species_hint": "cat",
  "body_shape": "small, compact",
  "fur_color": ["#d8a06a", "#f4e5cf"],
  "markings": ["face_white_stripe", "front_paws_white"],
  "eye_color": "#3d6b45",
  "ear_shape": "pointed",
  "tail": "medium, curved",
  "art_style": "soft 2.5D illustration"
}
```

提示词由模板拼接：`A {art_style} {species_hint} pet, {body_shape}, {fur_color}, {markings}, {eye_color}, same character, front-facing, solid neutral background, soft studio light, high detail, no text, no watermark`。条件图使用 `standing T-pose / curled sleeping / mid-walk stride`，并把同一 `seed`、同一 `art_style`、同一色彩卡作为跨状态锚点。生成模型会随机，所以“看起来像”只能通过参考图和评分闭环实现，不存在一次提示词保证身份。

**四层质量门比继续堆模型参数更有效。** 第一层是低阶物理检查：前景覆盖率、主体居中、四肢不出画、足/尾端点连续、骨架可达性。第二层是身份检查：身份帧与候选帧做嵌入相似度、颜色直方图、关键区域交叉注意力/分割重叠；阈值全部通过离线验证确定，报告不虚构绝对值。第三层是时序检查：相邻帧的 alpha 中心位移、轮廓面积变化率、毛发区域 SSIM、接触点相位；walk 检查首末帧配对误差。第四层是人审预览：展示 2–4 组候选，让用户选择“最像我家宠物”，但不要让用户理解模型参数。

若某状态首次未通过，先局部修复：重生成差异最大的帧；身份相似度低时固定种子并加强身份条件；四肢断裂时增加骨架/深度条件；alpha 抖动时重做抠图和边缘抗锯齿。只有连续两次局部修复失败后，才整体重生成。任何候选超过最大重试预算仍未通过，必须交付“可继续编辑的半成品”，并提供重新上传、更换模板、使用云端质量档或恢复旧宠物的明确入口。

## 六、目录、文件格式与版本规范：把素材做成可验证资产包

**素材目录应允许版本迁移和原子替换，而不是把一堆 PNG 散落在沙盒中。** 推荐结构：

```
~/Library/Containers/<team>.<bundle>/Data/Library/Application Support/<App>/
├─ input/
│  ├─ inbox/                      # 用户原始文件，生成完成后尽快删除
│  └─ selected/                   # 用户确认后的只读副本
├─ cache/
│  ├─ preprocessed/               # 主体、mask、缩略图
│  ├─ intermediate/               # 条件图、低质量候选、失败帧
│  └─ model_runtime/              # Core ML 编译缓存
├─ pets/
│  └─ <pet_id>/
│     ├─ manifest.json
│     ├─ identity/
│     │  ├─ reference.png
│     │  └─ reference@2x.png
│     ├─ source/
│     │  ├─ photo_001.heic
│     │  └─ photo_001_preview.jpg
│     ├─ poses/
│     │  ├─ idle.skeleton.json
│     │  ├─ sleep.skeleton.json
│     │  └─ walk.skeleton.json
│     ├─ frames/
│     │  ├─ idle/frame_00.png
│     │  ├─ sleep/frame_00.png
│     │  └─ walk/frame_00.png
│     ├─ clips/
│     │  ├─ idle.apng
│     │  ├─ idle.json
│     │  ├─ sleep.apng
│     │  ├─ sleep.json
│     │  ├─ walk.apng
│     │  └─ walk.json
│     ├─ menu/
│     │  └─ <size>pt/{idle,sleep,walk}.png
│     └─ preview/
│        └─ contact_sheet.png
└─ logs/
   └─ jobs/<job_id>.jsonl
```

`manifest.json` 采用语义化字段，不把内部 SDK 版本污染给用户：

```json
{
  "pet_id": "uuid",
  "schema_version": 1,
  "created_at": "ISO-8601",
  "art_style": "soft-2.5D",
  "generator": {
    "backend": "coreml-stable-diffusion",
    "base_model": "sdxl-derived-v1.2",
    "control": ["skeleton", "depth"],
    "quantization": "int8",
    "compute_units": "cpuAndGPU"
  },
  "input": {
    "photo_count": 2,
    "consent_scope": "on-device-only",
    "source_hashes": ["sha256"]
  },
  "quality": {
    "identity_similarity": 0.86,
    "frame_consistency": 0.91,
    "acceptance_state": "accepted-by-user"
  },
  "clips": [
    {
      "state": "idle",
      "frames": 8,
      "fps": 12,
      "loop": true,
      "contact_anchor": [0.50, 0.96],
      "frame_delay_ms": 83,
      "render_size_pt": [128, 128]
    }
  ],
  "privacy": {
    "uploaded_to_cloud": false,
    "cloud_provider": null,
    "deleted_from_device_after_export": false
  }
}
```

图片统一 PNG-24 + 预乘 alpha，alpha 采用 8 bit；不要在生成中间阶段反复保存 JPEG。最终动画优先 APNG：无损、支持可变帧延时和透明、可用单文件分发，便于在 macOS 视图中解码和测试。WebP 可作为可选高压缩交付格式，但不应替代母版 PNG。若资产需要定点、循环事件或触发放大/眨眼，JSON 中的 `frame_event` 可标记 `blink=true`、`contact=left_front_paw`，但首版只实现播放，不因此增加模型复杂度。

`schema_version` 必须参与资源加载。后续增加尾巴控制、视频局部合成或云方案时，只增加字段并在读取端做 `unknown field ignore` 与 `min schema version` 判断。资源包写入采用临时目录 + `rename` 的原子替换；预览目录可随时删除，但 `identity` 和 `frames` 是重生成基础，应保留到用户明确“删除宠物”。

## 七、播放状态机：状态切换看接触点，帧推进看显示时钟

**状态机的输入是业务事件，而不是原始定时器。** 定义 `Boot → Idle → Sleep` 与 `Idle/Walk/Sleep` 之间的合法迁移；`Generating/Error` 属于全局覆盖状态。建议规则：系统空闲超过阈值进入 idle，更长无输入且处于充电/用户允许时进入 sleep；用户显式“遛弯”或在桌面宠物模式进入 walk；菜单打开、屏幕锁定、低电量、生成任务运行时暂停或降频。状态切换不立即切图，而应先完成当前循环，除非存在打断条件。

```swift
enum PetState: Hashable {
    case idle, sleep, walk, generating(progress: Double), error(reason: String)
}

struct ClipAsset {
    var cgImages: [CGImage]
    var delays: [TimeInterval]
    var contactAnchors: [(x: CGFloat, y: CGFloat)]
    var loopStart: Int
}

final class PetPlayer {
    private var state: PetState = .idle
    private var clips: [PetState: ClipAsset] = [:]
    private var currentIndex = 0
    private var accumulator: TimeInterval = 0
    private var displayLink: CADisplayLink?

    func setState(_ next: PetState, immediate: Bool) {
        guard next != state else { return }
        guard isValidTransition(state, next) || immediate else { return }
        state = next
        currentIndex = 0
        accumulator = 0
    }

    @objc func tick(_ sender: CADisplayLink) {
        let deadline = sender.targetTimestamp - CACurrentMediaTime()
        guard deadline > 0 else {
            recoverMissedFrame(); return
        }
        guard let clip = clips[state] else { return }
        accumulator += sender.duration
        let frameDuration = clip.delays[currentIndex]
        while accumulator >= frameDuration {
            accumulator -= frameDuration
            currentIndex = (currentIndex + 1) % clip.cgImages.count
        }
        render(clip.cgImages[currentIndex], anchor: clip.contactAnchors[currentIndex])
    }
}
```

walk 的播放不是单纯帧循环，还包括平移相位。把接触锚点定义为相对于帧底边的 `(x, y)`，通常接近 `(0.5, 0.95–1.0)`；宠物沿地面移动时，先按帧更新脚部相位，再按物理时钟更新位置。若窗口边界即将碰撞，状态机可触发 turn-around：先播放固定转身帧、水平翻转并修正朝向，再继续。首版不必实现真实物理，但必须实现“地面基准线 + 锚点”，否则 idle、sleep、walk 切换时宠物会明显上下跳动。

**预解码和分层更新比 SwiftUI 重复重绘更适合长驻动画。** 静止背景/阴影作为底层 `CALayer`，宠物帧作为中间层，交互气泡/触发放大作为顶层。仅在状态改变时换帧，不用 SwiftUI `withAnimation` 控制逐帧播放；需要着色、发光、阴影时用 Core Image 滤镜链，不用每帧重新布局视图。Core Animation 明确提供逐帧时间控制，应使用 `targetTimestamp` 而非系统时间差累积[7]。菜单栏模式默认暂停动画、降低播放 fps、停止后台模型推理；桌面宠物模式才允许完整 walk。

内存上限应分三级：生成任务、播放任务和峰值系统余量。Core ML 生成阶段至少按“模型权重 + 权重解包峰值 + 采样中间张量 + 解码前后图像 + 系统图形缓存”估算，不能用权重文件大小代替驻留内存。播放阶段按 `width × height × 4 bytes × decoded-frame-count + display-cache` 估算。例如 256 pt 在 2× Retina 为 512 px，8 张 RGBA 帧约 8 MB；菜单栏 160 pt/2× 为 320 px，8 帧约 3.3 MB。这里不含 Core Animation 双缓冲、解码队列与系统开销，实际应以 `os_proc_available_memory` 和 Instruments 的 Allocation/Leaks/VMTracker 测量。

## 八、性能与内存：把模型配置和硬件能力拆开管理

**推荐运行时是 M1 Pro/Max/Ultra 及更新芯片、16 GB 统一内存起步，不是旧款 Intel Mac。** Apple 官方给出 M4 Pro 最高 64 GB 统一内存、273 GB/s 带宽，M4 Max 最高 128 GB、546 GB/s[10][11]。统一内存不等于可全部用于模型：系统、图形、Xcode/App 本身和 Core ML 编译缓存都需占用。因此 16 GB 机器只承诺最小可用档和较小的采样设置；24 GB 可运行更高分辨率与量化模型；48/64 GB 以上才适合本地同时承载多个大模型和并行生成任务。

建议通过真实设备矩阵建立能力等级，而不是根据芯片名称硬编码：

| 能力等级 | 推荐硬件下限 | 默认档位 | 默认生成策略 | 建议磁盘预留 |
|---|---:|---|---|---:|
| Low | M1 8 GB | 640–704 生成、8 fps | 单状态串行、4-bit 权重、CPU/GPU 回退 | 12 GB |
| Standard | M1 Pro/M2 16 GB | 768 生成、12 fps | SDXL/ControlNet、8–12 帧串行 | 20 GB |
| High | M3/M4 Pro 24 GB | 1024 生成、12 fps | 身份参考 + 局部视频驱动、可并行 1–2 任务 | 35 GB |
| Studio | M4 Max/Ultra 48 GB+ | 1024–1152、12–24 fps 局部合成 | 多候选 + 质量门并行 | 60 GB |

这些不是官方最低配置，而是独立开发者的工程建议，必须在版本发布前实测。Apple 的官方 M1 Max 示例显示 46 秒端到端和 0.46 iter/s[2]，只能证明该类管线可以运行；目标机型、量化、模型变体、批处理和系统版本不同，耗时会相差数倍。产品应展示预估时间与剩余时间，允许取消，并在电量低于阈值、温度过高、可用内存不足时暂停。

推理参数建议从以下候选开始，但把数值作为实验旋钮：

- SDXL 类：20–28 步，CFG 4–7；低资源档可降至 15–20 步；
- FLUX 类：若采用支持少步推理的版本，从官方推荐步数开始，绝不以 SDXL 步数套用；
- ControlNet 权重：0.6–1.0，起始/结束控制比例可用 0.0–0.9/0.1–1.0，控制过强会导致毛色被骨架图污染；
- 采样器：先做 Euler a / DPM++ 2M Karras 的视觉与时延对照；
- 生成数：每个状态产生 2 个候选，质量门选出 1 个，不把成本提高到 4 个以上。

Core ML 转换时记录工具版本、模型哈希、权重、量化、输入输出形状、目标 macOS 和 `computeUnits`；运行时记录实际 EP、首次编译时间、预热预测时间、后续预测时间、峰值内存、失败原因与降级链。Xcode 的 Core ML 性能报告可显示各操作的 CPU/GPU/NE 分配、首次/缓存加载与预测时间，并支持跨设备、跨配置比较[12]，应把它纳入验收，而不是只在 UI 里计时。

## 九、离线/联网降级：默认离线，云端是显式购买的能力

**云端开关必须建立在本地能力协商之后。** App 启动时只检查“是否需要下载用户已选择的可选模型”，不探测宠物生成 API。本地模式打开后，状态页清楚显示“照片不会上传”。用户主动选择“尝试云端高质量生成”时，才展示：服务商与处理地点、数据保留期限、是否用于训练、是否可删除、输出许可、价格和失败退款/重试规则。没有勾选明确同意前，任何上传按钮都应禁用。

云端客户端设计成独立 `RemoteGenerator`：协议与本地 `LocalGenerator` 相同，只返回候选帧、条件图、质量评分和审计信息。上传范围最小化：默认只传预处理后的身份裁切和骨架/深度条件，不传原始照片；若云模型必须接受原图，应明确警告。所有请求使用 TLS、证书钉扎或发布版本锁定的 SDK、一次性任务令牌、请求/响应签名、超时和幂等 `job_id`。模型下载应支持断点续传、SHA-256 校验、签名验证、后台暂停和存储不足提示；CoreML EP 可配置 `ModelCacheDirectory` 缓存编译图[8]，不要每次启动重新编译。

降级顺序应可测试：本地全功能 → 本地低资源档 → 用户同意的云端草稿 → 用户同意的云端高质量 → 仅静态头像/系统内置预设 → 明确错误。每一项降级都要改变界面提示，不能默默把一张预设宠物当成用户照片生成结果。离线时隐藏云端选项、禁用上传、保留队列；网络恢复后不自动发送排队中的敏感照片，需用户重新确认。

## 十、隐私、安全与用户控制：照片只进必要处理链，元数据默认剥离

**最小权限原则比功能齐全更重要。** 默认用 `NSOpenPanel` 让用户选择 1–3 张照片，避免 Photos 全库访问；若提供图库导入，优先使用 Photos Picker，只有确实需要读取/写入时才请求相应授权，并给出用途说明。处理前将图像复制到 App 容器 `input/selected`，工作副本剥离 GPS、设备序列号等敏感元数据；原始文件不要复制到临时目录后再遗忘删除。生成完成后删除 `inbox` 和中间张量，身份母版按用户选择保留或删除。

权限和存储建议：

| 用途 | 默认权限 | 实现建议 |
|---|---|---|
| 选择 1–3 张照片 | 用户选定文件只读 | `NSOpenPanel` |
| 访问用户照片库 | 不申请 | 只有用户选择图库入口时申请 |
| 生成推理 | 无网络 | 完全本地；App Sandbox 不开网络出口 |
| 模型下载 | 仅 Wi-Fi 可选 | 用户确认后再启用 |
| 云端高质量 | 用户逐次确认 | 独立开关、审计日志、可撤销 |
| 保存生成结果 | 用户选择目录 | `NSOpenPanel` 保存，不做自动外发 |

照片哈希只用于去重和任务幂等，不要生成可反向识别用户的全局画像。遥测默认关闭；开启后只上报匿名任务事件，如模型名称、分辨率档、失败阶段、重试次数和耗时区间，不传缩略图、提示词、地理位置或用户 ID。若使用崩溃报告，明确提供“发送/不发送”选择，并过滤文件路径、宠物名、系统账户信息。

AI 处理必须尊重他人权利。首次运行提示不得上传他人照片、儿童照片、敏感场景或未获授权的宠物；无法可靠自动判断权利归属，因此这必须是用户声明，而非 App 声称自动合规。生成素材只用于用户设备内展示；若允许导出，说明导出格式、分辨率和第三方服务。若模型或云端服务商许可证禁止商业使用，客户端应禁止“用于商业用途”开关。许可证检查应读取发布时可验证的模型卡和条款，不应在运行时凭第三方文章判定。

## 十一、失败重试与质量兜底：给用户结果，而不是暴露模型堆栈

**重试必须区分可恢复失败与永久失败。** 可恢复错误包括模型加载超时、编译失败、内存压力、推理超时、网络中断、下载校验失败；永久错误包括不支持芯片、磁盘权限失败、许可证拒绝、用户取消。指数退避推荐为 0.5 s、1 s、2 s、4 s，总尝试不超过 3–4 次；内存失败不应立即重试同一大配置，应先降档、释放模型、请求系统内存压力通知，仍失败则转静态身份帧。

重试策略示例：

1. 第一次失败：保留已通过质量门的前序帧，释放缓存并重试同一配置；
2. 第二次失败：将生成分辨率降低一档，或把 ControlNet 权重降到次高预设；
3. 第三次失败：从 `cpuAndGPU` 切到 `cpuOnly`、降低采样步数，仅生成 4 帧草稿；
4. 仍失败：交付静态身份头像 + 状态文本，让用户选择原图重选、模板重选、云端生成或稍后重试；
5. 云端失败：绝不使用云端照片继续本地训练，也不自动重试到不同服务商。

兜底资产分三级：A 级是全部三态通过质量门；B 级是 idle/sleep 通过、walk 使用程序化平移的 idle 帧；C 级只有一张身份头像，菜单栏显示静帧，用户开启桌面宠物时给出明确降级提示。walk 不应简单左右翻转一帧，至少准备抬腿相位；若无法生成可靠循环，就显示 idle 并把该状态置为“不可用”，优于不断抖动的错误素材。

每个生成任务写入 `jobs/<job_id>.jsonl`，至少包含 `event, timestamp, stage, model_config_hash, elapsed_ms, memory_bytes, quality_metrics, error_code, fallback_level`。这既用于失败诊断，也用于后续做消融实验：哪套提示词、骨架、控制权重和分辨率能在目标机型达到质量/时延 Pareto 最优。模型版本与配置变更要重建测试集结果，禁止“替换模型但不更新基准”。

## 十二、里程碑与验收：先用一周做出 8 帧可用，再用四周验证高质量

**最小可用 MVP 不需要训练模型。** 第 1 周完成 AppKit 状态项、上传界面、主体选择、静态身份图、idle 8 帧、Core ML 本地推理与 APNG 播放；第 2 周加入 sleep/walk 模板、骨架/深度条件、失败重试与质量评分；第 3 周完成沙盒、隐私说明、磁盘清理、降级、无障碍和崩溃安全；第 4 周在 M1 8 GB、M1 Pro 16 GB、M3/M4 Pro 24 GB、M4 Max 48 GB 上建立基准。首个内测版本只支持猫/狗和少量明确模板，不接受“任意动物任意动作”的开放承诺。

高质量阶段才做身份参考模型、跨帧时序注意力/视频动画后端、尾巴和耳朵次级动画、模型量化精调。每一项新增都需做 A/B 盲测：10–20 组不同品种、毛色和拍摄条件，至少比较身份相似度、姿态准确率、轮廓/接触点稳定性、平均推理时延和峰值内存；评分由自动指标与人评共同决定。若新模型只在某一指标更好，却显著增加内存或身份漂移，不应默认上线。

最终验收清单应包括：

- 上传 1、2、3 张照片分别生成成功；
- HEIC、JPEG、PNG 均可摄入，方向正确、元数据剥离；
- 在断网状态下完成整个本地生成流程；
- idle/sleep/walk 切换不跳动，walk 可循环且不闪烁；
- 取消任务后释放模型，内存回到基线；
- 低内存、模型编译失败、下载损坏时均有明确降级；
- 未授权图库时 App 仍可运行；
- 关闭遥测后无照片、缩略图或敏感元数据外发；
- VoiceOver 能识别状态栏宠物用途，菜单项标签简短清晰；
- 资源包可被新版本读取，未知字段不导致崩溃。

技术路线最大的不确定性不是“有没有模型”，而是动物通用骨架、身份一致性、Mac 本地时延和许可证兼容性同时成立。首版把可确定性最高的模板生成做到稳定，云端与最新视频模型放在可替换适配层，是独立开发者风险最低、交付最快、也最利于后续升级的方案。

## 引用来源

[1] https://developer.apple.com/documentation/appkit/nsstatusitem?ref=appcoda.com
> “class let squareLength: CGFloat A status item length that is equal to the status bar’s thickness.”

[2] https://github.com/apple/ml-stable-diffusion
> “–quantize-nbits: Quantizes the weights of unet and text_encoder models down to 2, 4, 6 or 8 bits using a globally optimal k-means clustering algorithm.”

[3] https://developer.apple.com/documentation/security/app_sandbox
> “App Sandbox provides protection to system resources and user data by limiting your app’s access to resources requested through entitlements.”

[4] https://stablediffusionxl.com/?p=448
> “Stable Diffusion XL was trained at a base resolution of 1024 x 1024.”

[5] https://developer.apple.com/documentation/vision/applying-matte-effects-to-people-in-images-and-video?changes=l_1
> “The app can set the value for request’s qualityLevel property to .fast, .balanced, or .accurate.”

[6] https://liveportrait.github.io/
> “By fine-tuning on animals data, these cute cats, dogs and pandas can be precisely driven by humans.”

[7] https://developer.apple.com/documentation/QuartzCore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays?changes=_4
> “Always use targetTimestamp to drive any animation, physics, or other time-related content provided in your CADisplayLink callback.”

[8] https://www.onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider
> “ModelFormat can be one of the following values: (NeuralNetwork by default ) - MLProgram.”

[9] https://apple.github.io/coremltools/docs-guides/source/typed-execution.html
> “The Core ML runtime dynamically partitions the network graph into sections for the Neural Engine (NE), GPU, and CPU.”

[10] https://www.apple.com/hk/en/newsroom/2024/10/apple-introduces-m4-pro-m4-max/
> “M4 Pro supports up to 64GB of fast unified memory and 273GB/s of memory bandwidth.”

[11] https://www.apple.com/tw/shop/product/g1cdeta/a/Mac-Studio-Apple-M4-Max-%E6%99%B6%E7%89%87%E9%85%8D%E5%82%99-16-%E6%A0%B8%E5%BF%83-CPU-%E8%88%87-40-%E6%A0%B8%E5%BF%83-GPU-%E6%95%B4%E4%BF%AE%E5%93%81?afid=p239%7C1318565&cid=aos-tw-aff-other-1318565-exelyans
> “546GB/s 記憶體頻寬”

[12] https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode?changes=_5_5&language=objc
> “Read the compute unit for each operation.”

[13] https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
> “The menu bar at the top of the screen displays the top-level menus in your app or game.”

[14] https://developer.apple.com/la/videos/play/wwdc2023/10176/
> “Discover how you can easily pull the subject of an image from its background in your apps.”

[15] https://arxiv.org/html/2407.03168v1
> “We find our model can generalize well to animals, e.g., cats and dogs, by fine-tuning on a small dataset of animal portraits combined with the original data.”
