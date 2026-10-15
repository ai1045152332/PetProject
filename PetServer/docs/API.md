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

## 2. 激活码验证

设置面板「权限」解锁的远程校验。App 端先比对本地校验码（456），
不匹配时再调用本接口。激活码由服务端生成并持久化在 `data/activation_codes.json`，
每个码最多绑定 `maxDevices` 台设备（按设备 ID 去重，同一设备重复激活不占用名额）。

```
POST /api/access/verify
```

### 请求字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| code | string | 是 | 用户输入的激活码（不区分大小写），格式 `XXXX-XXXX-XXXX` |
| deviceId | string | 是 | 设备唯一标识（macOS IOPlatformUUID） |

### 请求示例

```bash
curl -X POST http://11.0.213.233:8080/api/access/verify \
  -H "Content-Type: application/json" \
  -d '{"code": "9MDW-TCZ5-YVD8", "deviceId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"}'
```

### 成功响应

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "valid": true,
    "reason": "ok"
  }
}
```

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| data.valid | bool | 是否激活通过 |
| data.reason | string | `ok` 通过 / `invalid_code` 激活码不存在 / `expired` 激活码已过期 / `device_limit` 设备数达上限 |

### 失败响应

| 场景 | HTTP 状态码 | 响应 |
| --- | --- | --- |
| 非 POST 请求 | 405 | `{"code":405,"msg":"method not allowed"}` |
| 请求体不是合法 JSON | 400 | `{"code":400,"msg":"invalid json: ..."}` |
| 缺少 code 字段 | 400 | `{"code":400,"msg":"missing field: code"}` |

> 注意：激活失败（`valid: false`）属于正常业务结果，HTTP 状态码仍为 200，按 `reason` 区分原因。

---

## 3. 管理后台接口

### 3.1 登录

后台使用账号密码登录，登录成功后签发 24 小时有效的会话令牌。
账号密码通过环境变量 `PETSERVER_ADMIN_USER`（默认 `admin`）与 `PETSERVER_ADMIN_PASSWORD` 配置
（launchd plist 的 `EnvironmentVariables`）；未配置密码时管理接口一律返回 403。

```
POST /api/admin/login
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| username | string | 是 | 管理员账号 |
| password | string | 是 | 管理员密码 |

请求示例：

```bash
curl -X POST http://11.0.213.233:8080/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "123456"}'
```

响应：

```json
{"code":0,"msg":"ok","data":{"token":"b2b9e7...","expiresAt":"Fri, 16 Oct 2026 14:37:00 GMT"}}
```

### 3.2 退出登录

```
POST /api/admin/logout
```

请求头需带会话令牌：`X-Session-Token: <token>`。

### 3.3 鉴权方式

管理接口（生成/查询激活码）支持两种凭证：

| 方式 | 请求头 | 适用场景 |
| --- | --- | --- |
| 会话令牌 | `X-Session-Token: <登录返回的 token>` | 网页后台 |
| 管理密码 | `X-Admin-Token: <PETSERVER_ADMIN_PASSWORD>` | 脚本 / curl |

### 3.4 生成激活码

```
POST /api/admin/codes/generate
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| count | int | 是 | 生成数量，1~100 |
| maxDevices | int | 否 | 每码最多绑定设备数，1~10，默认 3 |
| validDays | int | 否 | 有效期天数，0~3650，默认 0（永久有效） |
| note | string | 否 | 备注（购买渠道/买家等） |

请求示例：

```bash
curl -X POST http://11.0.213.233:8080/api/admin/codes/generate \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: 123456" \
  -d '{"count": 5, "maxDevices": 3, "validDays": 365, "note": "面包多订单"}'
```

响应：

```json
{"code":0,"msg":"ok","data":{"codes":["9MDW-TCZ5-YVD8","TNZW-SFYM-EQCN"]}}
```

### 3.5 查询激活码列表

```
GET /api/admin/codes
```

请求示例：

```bash
curl http://11.0.213.233:8080/api/admin/codes -H "X-Admin-Token: 123456"
```

响应：

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "codes": [
      {
        "code": "9MDW-TCZ5-YVD8",
        "maxDevices": 3,
        "devices": ["XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"],
        "createdAt": "2026-10-15T13:00:00+08:00",
        "expiresAt": "2027-10-15T13:00:00+08:00",
        "note": "面包多订单"
      }
    ]
  }
}
```

> `expiresAt` 为 `null` 表示永久有效。

### 3.6 管理接口错误

| 场景 | HTTP 状态码 | 响应 |
| --- | --- | --- |
| 未配置管理密码 | 403 | `{"code":403,"msg":"admin api disabled (PETSERVER_ADMIN_TOKEN not set)"}` |
| 账号或密码错误 | 401 | `{"code":401,"msg":"账号或密码错误"}` |
| 会话失效/凭证缺失 | 401 | `{"code":401,"msg":"unauthorized"}` |
| 参数非法 | 400 | `{"code":400,"msg":"count must be 1~100"}` |

## 4. 后台页面

| 路径 | 说明 |
| --- | --- |
| `GET /admin/login` | 登录页（账号密码） |
| `GET /admin` | 菜单一：小猫在线列表 |
| `GET /admin/codes` | 菜单二：激活码管理（激活码/设备绑定/备注/生成时间/过期时间） |
| `GET /online`（或 `/`） | 手机版在线宠物页（免登录） |
