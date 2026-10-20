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
    ├── web/                            # 内置 H5 页面（go:embed）
    └── storage/heartbeat_store.go      # 存储：心跳 JSON Lines 落盘
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
| `POST /api/admin/codes/generate` | 管理：生成激活码（需 `X-Admin-Token`） |
| `GET /api/admin/codes` | 管理：激活码列表（需 `X-Admin-Token`） |
| `GET /online`（或 `/`） | H5 在线宠物列表页，手机浏览器直接访问 |
| `POST /api/admin/login` | 后台登录（账号密码，返回 24h 会话令牌） |
| `GET /api/app/latest` | 客户端检查更新（版本/sha256/Ed25519 签名） |
| `GET /download/<file>` | 下载 App 安装包（zip） |
| `GET /admin/login` | 后台登录页 |
| `GET /admin` | 后台菜单一：小猫在线列表（Tabler UI） |
| `GET /admin/codes` | 后台菜单二：激活码管理（含有效期/过期时间） |

> 在线判定：App 每 1 分钟上报一次心跳，最近 3 分钟内有心跳视为在线。
> H5 页面通过 `go:embed` 内置在二进制中，与 `/api/devices` 同源，无需额外部署或处理跨域。

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

## 自定义宠物图片（macOS）

macOS「设置 → 宠物」可上传一张 PNG/JPEG 照片，应用于所有状态；单张上限 10 MiB、4000 万像素，等比显示并保留 PNG 透明背景，不自动抠图或生成动画。

上传、历史列表、切换和下载均要求有效且已绑定当前设备的**服务端激活码**；本地快捷码不支持这些接口。图片归属由 IOPlatformUUID 识别，重装应用后在同一设备重新输入有效服务端激活码即可恢复历史和当前选择。换机不自动迁移。

- 服务器持久化目录：`data/pet-images/objects/`（原始图片）、`data/pet-images/libraries/`（每设备历史及当前选择）。备份时应同时备份两者和激活码库。
- 恢复默认只清空当前选择，历史保留；上传新图片不覆盖旧图。
- 客户端缓存当前图片，离线启动继续展示；联网启动或成功解锁时自动恢复服务器的当前选择。同步失败保留现有缓存，可重新打开应用重试。
- 首版不提供历史删除或自动清理，需按实际使用量管理磁盘空间。
- `storage.PetImageObjects` 隔离对象的写入、读取和删除；当前由 `LocalPetImageObjects` 实现。以后接入第三方存储时替换对象适配器，并迁移原有对象，客户端和历史中的图片 ID 不变。历史元数据继续保存在服务器。

先部署新服务端，再分发新客户端；旧服务端尚无图片接口。
