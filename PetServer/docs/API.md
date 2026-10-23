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
| sleep | 睡觉 |
| pet | 抚摸 |

旧版客户端（提醒状态移除前）的心跳可能仍会上报 `warn`，服务端照常接受并存储，仅展示时按未知状态处理。

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
会话持久化在 `data/sessions.json`，**服务重启或重新部署后登录态不丢失**。
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
  -d '{"username": "admin", "password": "<管理密码>"}'
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
| imageQuota | int | 否 | 每码 AI 生图终身总次数，0~100000，默认 0（未开通，不可生成） |
| note | string | 否 | 备注（购买渠道/买家等） |

请求示例：

```bash
curl -X POST http://101.96.248.75/api/admin/codes/generate \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: <管理密码>" \
  -d '{"count": 5, "maxDevices": 3, "validDays": 365, "imageQuota": 10, "note": "面包多订单"}'
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
curl http://101.96.248.75/api/admin/codes -H "X-Admin-Token: <管理密码>"
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
        "imageQuota": 10,
        "devices": ["XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"],
        "createdAt": "2026-10-15T13:00:00+08:00",
        "expiresAt": "2027-10-15T13:00:00+08:00",
        "note": "面包多订单"
      }
    ]
  }
}
```

> `expiresAt` 为 `null` 表示永久有效。`imageQuota` 为该码的 AI 生图终身总次数（0 = 未开通）。

### 3.5.1 设置激活码 AI 生图次数

生成后随时可改（调高/追加或调低/收回）某激活码的 AI 生图终身总次数上限；后台「激活码管理」每行的「改次数」按钮即调用此接口。

```
POST /api/admin/codes/quota
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| code | string | 是 | 激活码 |
| imageQuota | int | 是 | 新的总次数上限（绝对值，非增量），0~100000；0 = 收回（无法再生成） |

请求示例：

```bash
curl -X POST http://101.96.248.75/api/admin/codes/quota \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: <管理密码>" \
  -d '{"code": "9MDW-TCZ5-YVD8", "imageQuota": 20}'
```

响应：`{"code":0,"msg":"ok"}`；激活码不存在返回 `{"code":404,"msg":"code not found"}`。

> 本接口设置的是总上限（覆盖式）；调低到已用次数以下不会追回已扣量，仅使剩余归零。已用次数记在 `data/pet-images/libraries/quota-<码哈希>.json`，跨设备、重装不重置。

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
  -H "X-Admin-Token: <管理密码>" \
  -d '{"code": "TNZW-SFYM-EQCN"}'
```

响应：`{"code":0,"msg":"ok"}`；激活码不存在返回 `{"code":404,"msg":"code not found"}`。

### 3.7 设置设备备注

给在线设备（按主机名）打备注，如使用人/部门；备注会随设备列表返回。

```
POST /api/admin/devices/note
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| hostname | string | 是 | 设备主机名（取自设备列表） |
| note | string | 是 | 备注内容；传空字符串表示清除备注 |

请求示例：

```bash
curl -X POST http://101.96.248.75/api/admin/devices/note \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: <密码>" \
  -d '{"hostname": "mbp-xxx.local", "note": "赵健宇"}'
```

响应：`{"code":0,"msg":"ok"}`

> 备注持久化在 `data/device_notes.json`，服务重启/重新部署不丢。
> `GET /api/devices` 返回的每台设备会带 `note` 字段。

### 3.8 删除设备记录

从在线列表中移除某台设备的记录（内存 + 快照），备注一并清除。后台「在线宠物」页每行的删除按钮即调用此接口。

```
POST /api/admin/devices/delete
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| hostname | string | 是 | 设备主机名（取自设备列表） |

请求示例：

```bash
curl -X POST http://101.96.248.75/api/admin/devices/delete \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: <管理密码>" \
  -d '{"hostname": "mbp-xxx.local"}'
```

响应：`{"code":0,"msg":"ok"}`；记录不存在返回 `{"code":404,"msg":"device not found"}`。

> ⚠️ 心跳每 1 分钟上报一次，**仍在运行的设备删除后约 1 分钟内会重新出现**；
> 本接口用于清理长期离线、换机、重装系统留下的残留记录。

### 3.9 删除激活码


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
  -H "X-Admin-Token: <管理密码>" \
  -d '{"code": "K82M-E7C6-MWZV"}'
```

响应：`{"code":0,"msg":"ok"}`；激活码不存在返回 `{"code":404,"msg":"code not found"}`。

> 删除不可恢复，已绑定的设备记录会一并清除。

### 3.10 管理接口错误



| 场景 | HTTP 状态码 | 响应 |
| --- | --- | --- |
| 未配置管理密码 | 403 | `{"code":403,"msg":"admin api disabled (PETSERVER_ADMIN_TOKEN not set)"}` |
| 账号或密码错误 | 401 | `{"code":401,"msg":"账号或密码错误"}` |
| 会话失效/凭证缺失 | 401 | `{"code":401,"msg":"unauthorized"}` |
| 参数非法 | 400 | `{"code":400,"msg":"count must be 1~100"}` |

### 3.11 文件管理：列出目录

```
GET /api/admin/files/list?path=相对目录
```

- 所有文件操作锚定在根目录内（默认为**服务工作目录**，线上即 `/opt/petserver`，可同时浏览 `data/` 与 `dist/` 安装包；
  可用环境变量 `PETSERVER_FILES_ROOT` 覆盖），路径已净化，`../` 穿越会被限制在根目录内，越界直接拒绝
- `path` 留空表示根目录本身
- **敏感文件黑名单**：`*.env`、`*.pem`、`*.key`、`sessions.json` 会在列表中以 `sensitive=true` 标出，
  并**禁止预览与删除**（防止后台密码、RSA 私钥、会话令牌泄露或误删）

响应示例：

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "path": "",
    "root": "/opt/petserver",
    "files": [
      { "name": "activation_codes.json", "isDir": false, "size": 590, "modTime": "2026-10-15 15:40:32", "sensitive": false }
    ]
  }
}
```

### 3.12 文件管理：预览文件

```
GET /api/admin/files/preview?path=相对文件路径
```

响应：`data` 为 `{"path","content","size","truncated"}`；最多读取前 200 KB，
超出时 `truncated=true`（大文件/二进制文件不建议预览）。

### 3.13 文件管理：删除文件

```
POST /api/admin/files/delete
```

请求字段：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| path | string | 是 | 相对根目录的文件/目录路径 |

请求示例：

```bash
curl -X POST http://101.96.248.75/api/admin/files/delete \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: <管理密码>" \
  -d '{"path": "old_log.txt"}'
```

响应：`{"code":0,"msg":"ok"}`。

> ⚠️ 删除不可恢复；目录会递归删除；根目录本身禁止删除；敏感文件（`.env`/`.pem`/`.key`/`sessions.json`）禁止删除。

### 3.14 接口调用统计

服务端对所有请求做一层计数（中间件实现），按 `METHOD /path` 聚合调用次数、
成功/4xx/5xx 个数与耗时。只记接口名和数字，**不记录查询参数、请求体、响应体、IP、主机名**。

```
GET  /api/admin/metrics          # 查询统计（按调用次数倒序）
POST /api/admin/metrics/reset    # 清零，从当前时刻重新统计
```

请求示例：

```bash
curl http://101.96.248.75/api/admin/metrics \
  -H "X-Admin-Token: <管理密码>"
```

响应：

```json
{
  "code": 0,
  "msg": "ok",
  "data": {
    "generatedAt": "2026-10-21 16:44:05",
    "sinceAt": "2026-10-21 16:43:30",
    "totalCalls": 6,
    "errorCalls": 2,
    "endpoints": [
      {"key": "GET /api/devices", "total": 3, "success": 3, "clientErr": 0, "serverErr": 0,
       "latencyUs": 210, "maxLatencyUs": 90, "avgLatencyMs": 0.07, "maxLatencyMs": 0.09,
       "lastAt": "2026-10-21 16:44:01"}
    ]
  }
}
```

统计规则：

- 仅 `/api/*` 与 `/download/*` 按接口逐个统计；其余（官网页面、静态资源、后台 HTML、扫描探测）
  统一归入 `其他（页面/静态资源）`，避免噪声掩盖真实流量
- `GET /api/admin/metrics` 自身不计数（后台页每 10 秒轮询一次，计入会顶到榜首）
- 接口 key 上限 300 个，超限后新出现的未知路径并入噪声桶（防止随机路径刷爆内存）
- 计数内存累加，每 30 秒落盘到 `data/api_metrics.json`，**服务重启不丢累计**；清零会立即落盘
- 后台「服务器状态」页（`/admin/status`）底部有可视化表格与「清零重统计」按钮

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

## 5. 背单词词库接口

词库以 JSON 文件存放在服务器 `wordbank/` 目录（可用 `PETSERVER_WORDBANK_DIR` 覆盖），
通过后台文件管理页（/admin/files）维护，改词库无需重新发版。客户端启动后后台同步，
按文件字节数增量下载并缓存到本地，离线时使用缓存/内置词库。接口免登录。

### 5.1 词库列表

```
GET /api/wordbank/list
```

响应（`size` 为文件字节数，客户端据此判断是否需要重新下载）：

```json
{"code":0,"msg":"ok","data":{"banks":[{"name":"cet4","size":26817},{"name":"travel","size":7408}]}}
```

### 5.2 下载词库

```
GET /api/wordbank/get?name=cet4
```

直接返回词库 JSON 原文（`[{"word","meaning"}]` 数组）。词库名仅允许小写字母/数字/连字符
（`^[a-z0-9][a-z0-9-]*$`），非法名或不存在返回 `{"code":400,...}`。

> 首次部署需把词库文件上传一次：
> `rsync -a DesktopPetForMacApp/DesktopPetForMacApp/Resources/WordBank/ root@<host>:/opt/petserver/wordbank/`

## 6. 后台页面

| 路径 | 说明 |
| --- | --- |
| `GET /admin/login` | 登录页（账号密码） |
| `GET /admin` | 菜单一：小猫在线列表 |
| `GET /admin/codes` | 菜单二：激活码管理（激活码/设备绑定/备注/生成时间/过期时间/每码 AI 生图次数，可行内改次数） |
| `GET /admin/files` | 菜单三：文件管理（浏览/预览/删除服务器文件，默认锚定 `data/` 目录） |
| `GET /admin/status` | 菜单四：服务器状态（CPU/内存/网络流量 + 接口调用统计） |
| `GET /` | 官网落地页（产品介绍与 App 下载） |

## 自定义宠物图片

全部使用 `POST /api/pet-images/<action>`，响应禁止缓存。身份凭证为 `{ "code": "服务端激活码", "deviceId": "设备ID", "id": "图片ID（可选）", "state": "focus" }`，macOS 使用现有 RSA/AES 加密信封传输凭证。服务端仅接受仍有效且已绑定该设备的激活码，不在图片接口中绑定新设备。本地快捷码无效。

| action | 请求 | 返回 |
| --- | --- | --- |
| `list` | 加密凭证 JSON | `{code:0,msg:"ok",data:{currentId,currentIds:{focus:"图片ID"},images:[{id,state,name,contentType,createdAt,status,error,promptVersion}],generationLimit,generationRemaining}}`，历史由新到旧；`generationLimit`/`generationRemaining` 为该激活码的终身生成总上限/剩余次数 |
| `upload` | multipart/form-data：`auth` 为加密凭证字符串，`image` 为 PNG/JPEG 文件；`state` 可为具体状态或 `all` | 同上；返回 `beautifying` 任务，保存原图后异步生成，完成后才自动设为对应状态的当前图片。`state=all` 时为全部 4 个状态各创建一条任务并逐状态生成（整批只扣 1 次配额） |
| `retry` | 加密凭证 JSON，包含失败任务的 `id` 和 `state` | 同上；保留原图和任务 ID，重新生成 |
| `select` | 加密凭证 JSON，包含 `id` 和 `state`；空 ID 仅恢复该状态默认 | 同上，保留历史 |
| `content` | 加密凭证 JSON，包含 `id` | 已完成的图片字节；单帧模式生成结果为 `image/png`（动画模式为 `image/gif`）；旧静态历史仍返回 `image/png` 或 `image/jpeg` |

每张图片最大 10 MiB，宽高必须有效且总像素不超过 4000 万，服务端检查实际文件内容并完整解码验证。图片不公开挂载静态 URL，所有读取均经过设备授权；不能读取或选择其他设备的图片。400 表示参数/图片无效，403 表示未授权，404 表示图片不存在，405 表示方法不支持，429 表示并发任务已满，503 表示尚未配置 OpenRouter。未完成/失败任务不可选择或下载，返回 404。恢复接口不依赖本地缓存，重装后同设备重新激活即可获取原历史。


`status` 为 `beautifying`（提取美化）、`animating`（动画帧生成）、`encoding`（合成 GIF）、`ready`（可使用）、`failed`（失败）。旧记录没有 `status` 时等同 `ready`。客户端按 `state` 筛选历史（无 `state` 的旧记录可供所有状态使用），并轮询 `list` 等待任务结束；失败记录的 `error` 为可展示原因，不包含上游原始响应或 API Key。任务在服务器重启后标为 `failed`，需显式 `retry`，不自动重试计费调用。

上传/重试返回时选择保持原值。生成成功时更新 `currentIds[state]`；期间若发生对同一状态的 `select`（包括恢复默认），保留用户新选择，生成结果仍进入历史。操作其他状态不会阻止本状态结果自动应用。每设备同时 1 个生成任务，全服务最多同时生成 2 个任务。**生成总量按激活码终身累计**（不再按设备或每日重置）：同一码绑定的所有设备共享该码的总上限，上限在后台「激活码管理」按码配置（新码默认 0 = 未开通，不可生成），提交即扣次、失败不返还；超限时返回 429。


`state` 可取 `focus`、`idel`（沿用现有拼写）、`sleep`、`pet`、`hide`（贴边躲藏，只探出脑袋、一点前胸和一只小爪），上传还可用 `all` 触发逐状态扇出。历史提醒状态 `warn` 已合并进 `focus`，新上传/选择/重试不再接受 `warn`（返回无效状态错误），存量 `currentIds`/历史中的 warn 记录保留但由新客户端忽略。新客户端上传、选择和重试均发送对应状态，不能把一个状态专属的结果应用到其他状态。下载仍按设备和图片 ID 授权。为兼容旧客户端，缺少 `state`（空字串）时保留旧的共享图片行为；`currentId` 是旧共享选择，`currentIds` 显式键优先（包括空值，表示该状态恢复默认）。

生成器按当前帧模式处理上传记录的 `state`：单帧模式（当前写死）每个状态只发一次美化请求并输出透明 PNG；动画模式则传入美化和动画帧两次请求并合成 GIF。使用 `pet-seedream-state-v3` Prompt。专注生成工作/打字动作，睡觉生成全程闭眼蜷缩呼吸动作，躲藏生成贴边收窄探头动作，其余状态使用各自的姿态与动作。重试沿用原图和目标状态、使用当前 Prompt 版本。
