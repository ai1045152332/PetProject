# PetServer

桌面宠物（cute pet）后端 Go 服务。

## 结构

MVC 分层：

```
PetServer/
├── cmd/server/main.go                  # 入口：依赖组装、启动服务
└── internal/
    ├── model/                          # 模型：心跳、设备记录、校验码请求
    ├── service/                        # 业务：登记心跳、校验码验证
    ├── controller/                     # 控制器：解析请求、统一响应
    ├── router/router.go                # 路由注册
    ├── web/                            # 内置后台管理页与官网落地页（go:embed）
    └── storage/                        # 存储：心跳 JSON Lines 落盘；好友与消息走 SQLite（social_sqlite.go）
```

## 数据存储

所有状态都落在服务端工作目录的 `data/`（公网部署为 `/opt/petserver/data/`），重启/重新部署不丢：

| 文件 | 内容 | 说明 |
| --- | --- | --- |
| `heartbeats.jsonl` | 心跳日志（JSON Lines） | 每 5 分钟清理一次过期条目 |
| `devices.json` | 设备快照（主机名 → 最后心跳） | **重启后设备列表立即恢复**，无需等设备重新上报；30 天未上报自动丢弃 |
| `device_notes.json` | 设备备注 | 管理端维护，如使用人/部门 |
| `activation_codes.json` | 激活码（含设备绑定、有效期） | — |
| `sessions.json` | 管理后台登录会话 | 重启后登录态不丢 |
| `private_key.pem` | 载荷加密 RSA 私钥（0600） | 首次启动自动生成 |
| `petserver.db` | **好友与宠物消息（SQLite）** | 设备注册/宠物号、好友关系、待处理申请、收件箱、对话留痕；WAL 模式，备份时 `*.db`/`*-wal`/`*-shm` 一起搬 |
| `social.json` | 好友与消息的旧版单 JSON 存储 | 仅首次启用 SQLite 时作为导入来源，之后不再写入（保留不动，便于回滚与灾难恢复） |

### 好友与消息为什么单独进了 SQLite

这部分是典型的关系型数据（按接收设备查未读、按时间裁剪、只改一两行状态），其余仍用 JSON 整读整写。库只有一个写入进程（服务端自己），而 WAL 模式让读取不阻塞写入，所以下面这些方式都能本地直连：

```bash
cd PetServer && go run ./cmd/server        # 库落在 data/petserver.db（服务不用停）
sqlite3 data/petserver.db ".tables"        # devices friends requests messages history history_ids meta
sqlite3 -header -column data/petserver.db "select id,to_device,from_name,text,deliver_times from messages"
sqlite3 -header -column data/petserver.db "select kind,from_no,to_no,status,datetime(sent_ms/1000,'unixepoch','localtime') sent, read_ms from history order by seq desc limit 20"
```

图形界面用 IDEA 的 Database 工具窗口（Data Source 选 SQLite，指向该文件，建议勾 Read-only 免得 GUI 抢写锁）。时间列统一存 UnixMilli 整数，上面用 `datetime(x/1000,'unixepoch','localtime')` 转成可读时间。线上库同样只能先 `rsync` 拉到本地再看（没有端口可连，也不建议对外开放）。

环境变量：`PETSERVER_DB_PATH`（默认 `data/petserver.db`）。驱动用 `github.com/ncruces/go-sqlite3`（纯 Go + 内嵌 wasm），**不需要 CGO**，`GOOS=linux` 交叉编译与原有发布流程不变。

发布物在 `dist/`（`latest.json` + 各版本 zip），由 `DesktopPetForMacApp/release.sh` 上传。

## 接口

详细接口文档见 [docs/API.md](docs/API.md)。

| 接口 | 说明 |
| --- | --- |
| `GET /api/ping` | 连通性测试（浏览器可直接打开） |
| `POST /api/heartbeat` | 心跳上报：版本号 + 本机信息 + 宠物名/状态 |
| `GET /api/devices` | 在线宠物列表：返回所有设备及在线状态 |
| `GET /api/weather` | 天气查询（服务端代持上游 Key，按设备限流 30 次/小时） |
| `POST /api/access/verify` | 激活码验证（码 + 设备 ID，每码限绑定 N 台设备） |
| `POST /api/admin/codes/generate` | 管理：生成激活码（需 `X-Admin-Token`，可带每码 AI 生图次数 `imageQuota`） |
| `POST /api/admin/codes/quota` | 管理：设置/追加某激活码的 AI 生图总次数（需 `X-Admin-Token`） |
| `GET /api/admin/codes` | 管理：激活码列表（需 `X-Admin-Token`） |
| `GET /` | 官网落地页（产品介绍与 App 下载入口） |
| `POST /api/admin/login` | 后台登录（账号密码，返回 24h 会话令牌） |
| `GET /api/app/latest` | 客户端检查更新（版本/sha256/Ed25519 签名） |
| `GET /download/<file>` | 下载 App 安装包（zip） |
| `GET /admin/login` | 后台登录页 |
| `GET /admin` | 后台菜单一：小猫在线列表（Tabler UI） |
| `GET /admin/codes` | 后台菜单二：激活码管理（含有效期/过期时间/每码 AI 生图次数，可行内改次数） |

> 在线判定：App 每 1 分钟上报一次心跳，最近 3 分钟内有心跳视为在线。
> 官网与后台页面均通过 `go:embed` 内置在二进制中，无需额外部署静态资源。

## 运行

```bash
cd PetServer
go run ./cmd/server
# 或编译后运行
go build -o petserver ./cmd/server && ./petserver
```

默认监听 `:8080`。

> 发布与自动更新流程见 [`docs/自动更新与发布流程.md`](../docs/自动更新与发布流程.md)。

> 部署：公网服务器 `101.96.248.75`（监听 80 端口，systemd 管理，数据在 `/opt/petserver/data`）。
> App 端地址写在 `DesktopPetForMacApp/Services/ServerConfig.swift`，加密公钥写在
> `PayloadCrypto.swift`；**两者必须与目标后端一致**（每台服务端各自生成密钥对）。
> 修改后端地址后需重新打包 App。

## AI 自定义宠物（macOS）

macOS「设置 → 宠物信息 → 自定义状态图片」提供两种上传：①「直接上传」把本机 PNG/JPEG/GIF 原图即时应用到所选状态（不经服务端、不占配额）；②「🪄 AI 生成全部状态」上传一张 PNG/JPEG 照片（最大 10 MiB、4000 万像素），服务端通过 OpenRouter Images API 调用 Seedream 4.5 为全部 4 个状态各生成一张图片（姿态按状态区分）并自动应用。**当前版本帧模式写死为单帧**：每个状态只发一次美化请求，输出透明背景 1024×1024 PNG 静态图；两阶段动画 GIF 管线代码保留在 `internal/service/pet_image_generator.go`，将 `petFrameModeAnimated` 改为 `true` 并重新编译即可切回。一次「AI 生成全部状态」整批只扣 1 次配额、占 1 个任务槽、服务端顺序生成；单状态的历史重试各自单独扣 1 次。原图不会在生成期间替换旧宠物。

### OpenRouter 配置

仅在服务器运行环境中设置（不要写入 Swift 客户端或提交密钥）：

```sh
export OPENROUTER_API_KEY="你的 OpenRouter API Key"
export PETSERVER_OPENROUTER_IMAGE_MODEL="bytedance-seed/seedream-4.5"  # 可选，默认值
```

> AI 生图次数不再由环境变量控制：每个激活码的终身生成总次数在后台「激活码管理」按码配置（生成时可填，也可随时用行内「改次数」编辑），新码默认 0 = 未开通，不配置则该码无法生成。

systemd 部署时在现有 EnvironmentFile 中添加上述配置并重启服务。本程序不会自动读取 `.env` 文件。使用 OpenRouter API Key 和余额计费；不再读取旧的 `OPENAI_API_KEY`，ChatGPT 订阅不能代替 API Key。默认模型为 `bytedance-seed/seedream-4.5`（支持参考图编辑，透明背景由服务端绿幕提取完成）。Seedream 使用 `resolution=2K`、`aspect_ratio=1:1`，不发送原生透明背景或质量参数；Seedream 4.5 实际要求至少 3,686,400 输出像素（1K 会返回 HTTP 400）。生成统一绿幕背景后，服务端移除与边界相连的绿幕并归一化为 1024×1024。其他模型需要具有图片编辑、PNG 和透明背景输出能力；更换模型后需重新验证。未配置 Key 时，上传/重试返回 503，历史读取与切换仍可使用。

- Prompt 版本为 `pet-seedream-state-v3`，模板位于 `internal/service/prompts/pet_portrait_v1.txt` 和 `pet_animation_v1.txt`，绿幕覆盖指令位于 `pet_chroma_v2.txt`，由 `go:embed` 打包，修改后重新编译服务端。状态姿态和动作位于 `internal/service/prompts/pet_states_v3.json`，参考 `skills/meijing-pet-prompts/references/prompts.md` 的风格与约束；单帧模式下每个状态只传入一次美化请求，动画模式则传入美化+动画帧两次，旧版无状态上传默认休闲。
- 单帧模式下每个状态一次 OpenRouter 图片生成请求（动画模式两次），不自动重试付费请求。一次「全部状态」上传为 4 个状态各生成一张，但整批只扣 1 次配额、占 1 个任务槽并顺序生成。全服务最多同时生成 2 个任务，每设备同时 1 个任务。**AI 生成总量按激活码终身累计**：同一码绑定的所有设备共享一个总次数上限，跨设备、重装、换机都不会重置；上限按码在后台「激活码管理」配置（新码默认 0 = 未开通，可随时调高/调低，含手动重试）。提交即扣次，生成失败不返还，避免反复失败刷量。`list` 会返回 `generationLimit`/`generationRemaining`，客户端展示剩余次数并在用完后禁用生成按钮。单个任务生成全过程最多 9 分钟。
- 任务状态：单帧模式为 `beautifying` → `ready` 或 `failed`（动画模式额外经过 `animating`、`encoding`）；客户端每 3 秒轮询。失败不替换旧宠物，可在历史中先选择状态，再选择失败任务并点击「重试生成」。服务器重启会将未完成任务标为失败，避免自动重复计费；保留原图供手动重试。
- 模型输出会检查尺寸、透明度、空帧和边界裁切。格式检查无法保证宠物身份、风格和帧间动作完全一致，实际效果需要使用真实照片验证；原始照片不应包含多个同等突出的宠物。
- 单帧模式输出透明背景 1024×1024 PNG 静态图；切回动画模式则使用 256×256 全画布帧、统一色板、明确透明索引和背景清除策略，10 FPS 正反向循环合成 GIF（GIF 仅支持二值透明，毛发半透明边缘会有损失）。
- 图片会经 OpenRouter 发送到 OpenAI 模型；客户端选图窗口会告知这一处理过程。

上传、历史、重试、切换和下载均要求有效且已绑定当前设备的服务端激活码，本地快捷码不支持。按 IOPlatformUUID 归属，重装应用后同设备重新输入有效激活码即可恢复历史和当前选择。

持久化目录为 `data/pet-images/objects/`（原图和生成图片）与 `data/pet-images/libraries/`（历史、任务状态、按状态的当前选择，以及按激活码的终身生成次数账本 `quota-<码哈希>.json`）。备份时同时保留两者和激活码库。恢复默认会保留历史；生成期间对同一状态手动切换或恢复默认优先于生成完成后的自动选择，操作其他状态不会干扰此任务。客户端缓存当前 GIF，离线仍可播放；重新打开应用会继续查询服务器任务。

旧版静态历史记录继续可读，无 `status` 的记录视为已完成。旧版共享选择 `currentId` 作为未设置状态的回退；`currentIds` 按状态覆盖，空 ID 明确恢复该状态默认，不再回退。原有本地各状态图片保持可读，尚未使用云端的状态不会被清空。首版不提供历史删除/自动清理。`storage.PetImageObjects` 保留第三方存储接入点，生成后的图片也通过该接口保存。

先部署新服务端并配置 API Key，再分发新客户端。验证命令：`go test -race ./...`；macOS 工程执行 `swift test --disable-sandbox`。测试使用本地模拟 OpenRouter 响应，不会产生模型费用。

OpenRouter 接口使用 `POST https://openrouter.ai/api/v1/images`，JSON 中的 `input_references` 以 Base64 data URL 传入原图/美化图，输出读取 `data[0].b64_json`。不沿用 OpenAI multipart 请求，也不使用普通文本聊天模型。固定模型并关闭提供商自动 fallback。接口依据：[OpenRouter 图片生成文档](https://openrouter.ai/docs/guides/overview/multimodal/image-generation)。

Seedream 的背景提取使用边界连通的绿幕识别，保留不与背景相连的绿色眼睛等细节。绿色主体、复杂毛发和封闭背景区域仍可能出现残留或边缘损失，需要真实照片验证。

### 状态专属图片

| 上传状态 | 姿态和循环动作 |
| --- | --- |
| 专注 `focus` | 端坐在小笔记本电脑前，前爪交替轻打键盘、专注看屏幕，道具位置固定且无文字/徽标 |
| 休闲 `idel` | 四脚站立放松，轻微呼吸、眨眼、尾尖摆动 |
| 睡觉 `sleep` | 蜷缩趴卧、全程闭眼，只做缓慢呼吸，不醒来 |
| 抚摸 `pet` | 眯眼放松坐姿、轻歪头蹭空气，全程不出现人的手 |

共同采用3头身Q版卡通可爱风格，保留上传宠物的毛色、斑纹与五官，禁止地面阴影、人物、水印和状态串换。当前版本写死单帧静态输出（每个状态一张透明 PNG），多帧循环 GIF 管线代码保留、通过 `petFrameModeAnimated` 开关切回；多帧一致性仍需真实生成验证。已生成的历史图片不会因改 Prompt 自动变化，需新上传照片；失败任务重试使用新版本 Prompt。
