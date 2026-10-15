package controller

import (
	"net/http"

	"petserver/internal/crypto"
)

// CryptoController 载荷加密相关接口（下发公钥）
type CryptoController struct {
	keyPair *crypto.KeyPair
}

// NewCryptoController 创建加密控制器
func NewCryptoController(keyPair *crypto.KeyPair) *CryptoController {
	return &CryptoController{keyPair: keyPair}
}

// PubKey 处理 GET /api/crypto/pubkey
// 返回 base64(DER/SubjectPublicKeyInfo) 公钥；客户端（App 内置 / 网页 JSEncrypt）用它加密敏感字段
func (c *CryptoController) PubKey(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	if c.keyPair == nil {
		writeJSON(w, http.StatusServiceUnavailable, Response{Code: 503, Msg: "keypair unavailable"})
		return
	}

	pub, err := c.keyPair.PublicKeyBase64()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, Response{Code: 500, Msg: "encode public key failed"})
		return
	}

	writeJSON(w, http.StatusOK, Response{Code: 0, Msg: "ok", Data: map[string]any{
		"algorithm":      "RSA-OAEP-SHA256",
		"format":         "base64(DER SubjectPublicKeyInfo)",
		"publicKey":      pub,
		"publicKeyPkcs1": c.keyPair.PublicKeyPKCS1Base64(),
	}})
}
