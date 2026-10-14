# PetServer 接口文档

桌面宠物（cute pet）后端服务 HTTP 接口说明。

## 通用说明

- **Base URL**：`http://<host>:8080`（本地开发为 `http://11.0.213.233:8080`）
- **请求格式**：除 `GET /api/ping` 外均为 `POST` + `Content-Type: application/json`
- **统一响应信封**：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| code | int | 0 成功；400 参数错误；405 请求方法不允许 |
| msg | string | 结果描述（成功为 `ok`，失败为具体原因） |
| data | object | 业务数据，失败时无此字段 |

---

## 0. 连通性测试

供浏览器或 curl 直接访问，验证服务是否可达（无需请求体）。

```
GET /api/ping
```

### 请求示例

```bash
curl http://11.0.213.233:8080/api/ping
```

### 成功响应

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "service": "PetServer",
    "serverTime": "2026-10-14T15:00:00+08:00"
  }
}
```

---

## 1. 心跳上报

宠物 App 启动时立即上报一次，之后每 1 分钟上报一次。
服务端按主机名维护设备最近心跳（内存），并将每条心跳以 JSON Lines 追加到 `data/heartbeats.jsonl`。

```
POST /api/heartbeat
```

### 请求字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| version | string | 是 | App 版本号，如 `v1.0.001.test` |
| hostname | string | 是 | 主机名，如 `MacBook-Pro.local` |
| os | string | 是 | 系统版本，如 `macOS Version 15.6.1` |
| machine | string | 是 | 机器架构，如 `arm64` |
| petName | string | 是 | 宠物名称，默认 `毛豆` |
| petState | string | 是 | 宠物当前状态，见下方枚举 |

`petState` 枚举：

| 取值 | 含义 |
| --- | --- |
| focus | 专注 |
| idel | 休闲 |
| warn | 提醒 |
| sleep | 睡觉 |
| pet | 抚摸 |

### 请求示例

```bash
curl -X POST http://11.0.213.233:8080/api/heartbeat \
  -H "Content-Type: application/json" \
  -d '{
    "version": "v1.0.001.test",
    "hostname": "MacBook-Pro.local",
    "os": "macOS Version 15.6.1",
    "machine": "arm64",
    "petName": "毛豆",
    "petState": "idel"
  }'
```

### 成功响应

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "serverTime": "2026-10-14T15:00:00+08:00",
    "lastSeenAt": "2026-10-14T15:00:00+08:00"
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| data.serverTime | string | 服务器当前时间（RFC3339） |
| data.lastSeenAt | string | 本次心跳登记时间（RFC3339） |

### 失败响应

| 场景 | HTTP 状态码 | 响应 |
| --- | --- | --- |
| 非 POST 请求 | 405 | `{"code":405,"msg":"method not allowed"}` |
| 请求体不是合法 JSON | 400 | `{"code":400,"msg":"invalid json: ..."}` |
| 缺少必填字段 | 400 | `{"code":400,"msg":"missing field: petName"}` |

---

## 2. 校验码验证

设置面板「权限」解锁的远程校验。App 端先比对本地校验码（456），
不匹配时再调用本接口；远程校验码当前在服务端写死为 `123`
（`internal/service/access_service.go`）。

```
POST /api/access/verify
```

### 请求字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| code | string | 是 | 用户输入的校验码 |

### 请求示例

```bash
curl -X POST http://11.0.213.233:8080/api/access/verify \
  -H "Content-Type: application/json" \
  -d '{"code": "123"}'
```

### 成功响应

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "valid": true
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| data.valid | bool | 校验码是否正确 |

### 失败响应

| 场景 | HTTP 状态码 | 响应 |
| --- | --- | --- |
| 非 POST 请求 | 405 | `{"code":405,"msg":"method not allowed"}` |
| 请求体不是合法 JSON | 400 | `{"code":400,"msg":"invalid json: ..."}` |
| 缺少 code 字段 | 400 | `{"code":400,"msg":"missing field: code"}` |

> 注意：校验码错误（`valid: false`）属于正常业务结果，HTTP 状态码仍为 200。
