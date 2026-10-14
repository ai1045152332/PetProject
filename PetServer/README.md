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
    └── storage/heartbeat_store.go      # 存储：心跳 JSON Lines 落盘
```

## 数据存储

每条心跳以 JSON Lines 追加到 `data/heartbeats.jsonl`（相对服务的工作目录，
launchd 运行时为 `PetServer/`）。同时内存中按主机名维护每台设备的最近心跳。

## 接口

详细接口文档见 [docs/API.md](docs/API.md)。

| 接口 | 说明 |
| --- | --- |
| `POST /api/heartbeat` | 心跳上报：版本号 + 本机信息 + 宠物名/状态 |
| `POST /api/access/verify` | 校验码远程验证（远程码写死 123） |

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
