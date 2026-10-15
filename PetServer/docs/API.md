# PetServer 接口文档

桌面宠物（cute pet）后端服务 HTTP 接口说明。

## 通用说明

- **Base URL**：`http://<host>`（公网部署为 `http://101.96.248.75`，本地开发默认 `:8080`）
- **请求格式**：除 `GET /api/ping` 外均为 `POST` + `Content-Type: application/json`
- **统一响应信封**：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| code | int | 0 成功；400 参数错误；405 请求方法不允许 |
| msg | string | 结果描述（成功为 `ok`，失败为具体原因） |
| data | object | 业务数据，失败时无此字段 |

---

## 0. 载荷加密（应用层）

未部署 TLS 时，密码、激活码、设备 ID 等敏感字段通过应用层加密传输，网线上只有密文。

- **算法**：RSA-2048 + OAEP-SHA256（App 使用；服务端亦兼容 PKCS#1 v1.5，供网页端 JSEncrypt 使用）
- **服务端私钥**：默认 `data/private_key.pem`（0600，可用 `PETSERVER_PRIVATE_KEY_PATH` 覆盖），首次启动自动生成
- **请求格式**：把明文 JSON 用服务端公钥加密，请求体改为信封：

```json
{"encrypted": "<base64(RSA(明文JSON))>"}
```

- **适用接口**：`POST /api/admin/login`、`POST /api/access/verify`
- **携带限制**：RSA-2048 OAEP-SHA256 单条载荷上限约 190 字节，故这两类请求体都很小；如需加密更大载荷（如心跳），需改为混合加密（AES-GCM + RSA 包裹密钥）

### 获取公钥

```
GET /api/crypto/pubkey
```

响应：

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "algorithm": "RSA-OAEP-SHA256",
    "format": "base64(DER SubjectPublicKeyInfo)",
    "publicKey": "MIIBIjANBgkqhkiG9w0BAQEF...",
    "publicKeyPkcs1": "MIIBCgKCAQEA..."
  }
}
```

- `publicKey`：X.509 SubjectPublicKeyInfo（网页 JSEncrypt 可用）
- `publicKeyPkcs1`：PKCS#1（macOS Security 框架 `SecKeyCreateWithData` 需要）

> 客户端内置公钥与后端一一对应。切换后端地址时必须同步更新 App 内嵌公钥（`PayloadCrypto.swift`），否则解密失败。

### 命令行加密示例

```bash
# 1. 取公钥转 PEM
curl -s http://101.96.248.75/api/crypto/pubkey | python3 -c "
import sys, json, base64
der = base64.b64decode(json.load(sys.stdin)['data']['publicKey'])
b64 = base64.b64encode(der).decode()
print('-----BEGIN PUBLIC KEY-----')
print('\n'.join(b64[i:i+64] for i in range(0, len(b64), 64)))
print('-----END PUBLIC KEY-----')
" > pub.pem

# 2. 加密并请求
printf '{"username":"admin","password":"123456"}' > plain.json
openssl pkeyutl -encrypt -pubin -inkey pub.pem -in plain.json \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -out cipher.bin
python3 -c "
import base64, json
print(json.dumps({'encrypted': base64.b64encode(open('cipher.bin','rb').read()).decode()}))
" > envelope.json
curl -X POST http://101.96.248.75/api/admin/login \
  -H "Content-Type: application/json" -d @envelope.json
```

> 本地调试仍可直接发明文 JSON（服务端兼容），生产客户端应始终加密。

## 0.2 连通性测试

供浏览器或 curl 直接访问，验证服务是否可达（无需请求体）。

```
GET /api/ping
```

### 请求示例

```bash
curl http://101.96.248.75/api/ping
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
curl -X POST http://101.96.248.75/api/heartbeat \
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
curl -X POST http://101.96.248.75/api/access/verify \
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
curl -X POST http://101.96.248.75/api/admin/login \
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
curl -X POST http://101.96.248.75/api/admin/codes/generate \
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
curl http://101.96.248.75/api/admin/codes -H "X-Admin-Token: 123456"
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

### 3.6 解绑设备

用于测试数据清理或用户换机：解绑后该码可在新设备重新激活。

```
POST /api/admin/codes/unbind
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| code | string | 是 | 激活码 |
| deviceId | string | 否 | 指定解绑某台设备；留空表示解绑全部设备 |

请求示例（解绑全部）：

```bash
curl -X POST http://101.96.248.75/api/admin/codes/unbind \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: 123456" \
  -d '{"code": "TNZW-SFYM-EQCN"}'
```

响应：`{"code":0,"msg":"ok"}`；激活码不存在返回 `{"code":404,"msg":"code not found"}`。

### 3.7 删除激活码

```
POST /api/admin/codes/delete
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| code | string | 是 | 要删除的激活码 |

请求示例：

```bash
curl -X POST http://101.96.248.75/api/admin/codes/delete \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: 123456" \
  -d '{"code": "K82M-E7C6-MWZV"}'
```

响应：`{"code":0,"msg":"ok"}`；激活码不存在返回 `{"code":404,"msg":"code not found"}`。

> 删除不可恢复，已绑定的设备记录会一并清除。

### 3.8 管理接口错误



| 场景 | HTTP 状态码 | 响应 |
| --- | --- | --- |
| 未配置管理密码 | 403 | `{"code":403,"msg":"admin api disabled (PETSERVER_ADMIN_TOKEN not set)"}` |
| 账号或密码错误 | 401 | `{"code":401,"msg":"账号或密码错误"}` |
| 会话失效/凭证缺失 | 401 | `{"code":401,"msg":"unauthorized"}` |
| 参数非法 | 400 | `{"code":400,"msg":"count must be 1~100"}` |

## 4. App 更新接口

### 4.1 查询最新版本

```
GET /api/app/latest
```

响应（无发布版本时返回 404 `no release published`）：

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "version": "v1.0.002",
    "file": "cute-pet-v1.0.002.zip",
    "sha256": "674d566d8bff...",
    "signature": "4ygrNyMoV5UoP0q/...",
    "notes": "更新说明",
    "publishedAt": "2026-10-15T16:12:00+08:00",
    "size": 3634932,
    "minOS": "13.0"
  }
}
```

- `signature`：Ed25519 签名（base64），**签名对象为 `sha256` 的十六进制字符串**
- 客户端必须先比对 sha256，再用内置公钥验签，任一不通过都不得安装

### 4.2 下载安装包

```
GET /download/<file>
```

返回 zip（`Content-Type: application/zip`，支持断点续传）。仅允许访问 dist 目录内的文件。

### 4.3 发布流程

发布在开发者本机执行（私钥不出本机）：

```bash
cd DesktopPetForMacApp
./release.sh v1.0.002 "本次更新说明"
```

脚本依次完成：写入版本号（AppVersion.swift + Info.plist）→ 编译打包（签名）
→ 压缩 zip → 计算 sha256 → Ed25519 签名 → 生成 latest.json → 上传到
`/opt/petserver/dist/`。

> ⚠️ 签名私钥位于 `~/.cute-pet-release/ed25519_private.pem`，**丢失后无法再发布可被
> 已装客户端接受的更新**（客户端内置的对应公钥不可更改，只能强制用户重装）。
> 公钥内嵌在 `DesktopPetForMacApp/DesktopPetForMacApp/Services/UpdateService.swift`。

## 5. 后台页面

| 路径 | 说明 |
| --- | --- |
| `GET /admin/login` | 登录页（账号密码） |
| `GET /admin` | 菜单一：小猫在线列表 |
| `GET /admin/codes` | 菜单二：激活码管理（激活码/设备绑定/备注/生成时间/过期时间） |
| `GET /online`（或 `/`） | 手机版在线宠物页（免登录） |
