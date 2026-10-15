package controller

import (
	"io"
	"net/http"

	"petserver/internal/crypto"
)

// maxPayloadBytes 请求体上限（加密信封 base64 后约 400 字节，留足余量）
const maxPayloadBytes = 8 << 10

// ReadPayload 读取请求体并返回明文 JSON：
//   - 加密信封 {"encrypted": "..."} → 用服务端私钥解密
//   - 其它形式 → 视为明文（仅用于本地 curl 调试，客户端应始终加密）
func ReadPayload(r *http.Request, keyPair *crypto.KeyPair) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxPayloadBytes))
	if err != nil {
		return nil, err
	}
	if !crypto.IsEnvelope(body) {
		return body, nil
	}
	if keyPair == nil {
		return body, nil
	}
	return keyPair.DecryptEnvelope(body)
}
