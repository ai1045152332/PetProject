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

每条心跳以 JSON Lines 追加到 `data/heartbeats.jsonl`（相对服务的工作目录，
launchd 运行时为 `PetServer/`）。同时内存中按主机名维护每台设备的最近心跳。

## 接口

详细接口文档见 [docs/API.md](docs/API.md)。

| 接口 | 说明 |
| --- | --- |
| `GET /api/ping` | 连通性测试（浏览器可直接打开） |
| `POST /api/heartbeat` | 心跳上报：版本号 + 本机信息 + 宠物名/状态 |
| `GET /api/devices` | 在线宠物列表：返回所有设备及在线状态 |
| `POST /api/access/verify` | 激活码验证（码 + 设备 ID，每码限绑定 N 台设备） |
| `POST /api/admin/codes/generate` | 管理：生成激活码（需 `X-Admin-Token`） |
| `GET /api/admin/codes` | 管理：激活码列表（需 `X-Admin-Token`） |
| `GET /online`（或 `/`） | H5 在线宠物列表页，手机浏览器直接访问 |

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

> 注意：App 端后端地址目前写死为 `http://11.0.213.233:8080`，
> 本机 IP 变化时只需修改 `DesktopPetForMacApp/Services/ServerConfig.swift`。
