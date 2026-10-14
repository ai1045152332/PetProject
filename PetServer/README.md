# PetServer

桌面宠物（cute pet）后端 Go 服务。

## 结构

MVC 分层：

```
PetServer/
├── cmd/server/main.go                  # 入口：依赖组装、启动服务
└── internal/
    ├── model/heartbeat.go              # 模型：心跳、设备记录
    ├── service/heartbeat_service.go    # 业务：登记心跳、维护设备列表
    ├── controller/heartbeat_controller.go # 控制器：解析请求、统一响应
    ├── router/router.go                # 路由注册
    └── storage/heartbeat_store.go      # 存储：心跳 JSON Lines 落盘
```

## 数据存储

每条心跳以 JSON Lines 追加到 `data/heartbeats.jsonl`（相对服务的工作目录，
launchd 运行时为 `PetServer/`）。同时内存中按主机名维护每台设备的最近心跳。

## 接口

### POST /api/heartbeat

宠物 App 每 1 分钟上报一次心跳，携带本机简单信息与版本号。

请求体示例：

```json
{
  "version": "v1.0.001.test",
  "hostname": "MacBook-Pro.local",
  "os": "macOS Version 15.0",
  "machine": "arm64",
  "petName": "毛豆",
  "petState": "idel"
}
```

`petState` 取值：`focus`（专注）/ `idel`（休闲）/ `warn`（提醒）/ `sleep`（睡觉）/ `pet`（抚摸）。

响应：

```json
{"code":0,"msg":"ok","data":{"serverTime":"2026-10-14T15:00:00+08:00","lastSeenAt":"2026-10-14T15:00:00+08:00"}}
```

### POST /api/access/verify

设置面板「权限」校验码的远程校验。App 端先比对本地校验码（456），
不匹配时再请求本接口；远程校验码当前在 `internal/service/access_service.go` 写死为 `123`。

请求体：

```json
{"code": "123"}
```

响应：

```json
{"code":0,"msg":"ok","data":{"valid":true}}
```

## 运行

```bash
cd PetServer
go run ./cmd/server
# 或编译后运行
go build -o petserver ./cmd/server && ./petserver
```

默认监听 `:8080`。

> 注意：App 端心跳地址目前写死为 `http://11.0.213.233:8080/api/heartbeat`，
> 本机 IP 变化时需同步修改 `DesktopPetForMacApp/Services/HeartbeatService.swift`。
