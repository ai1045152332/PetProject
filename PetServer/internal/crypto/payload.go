// Package crypto 应用层载荷加密：服务端持 RSA 私钥，客户端用公钥加密敏感字段。
// 用途：在未部署 TLS 的情况下，避免密码 / 激活码 / 设备 ID 以明文过网。
package crypto

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"os"
	"path/filepath"
)

// keyBits RSA 密钥长度（OAEP-SHA256 下单个载荷上限约 190 字节，足够覆盖登录/激活请求）
const keyBits = 2048

// KeyPair 服务端密钥对
type KeyPair struct {
	Private *rsa.PrivateKey
}

// LoadOrCreate 读取私钥文件，不存在则生成并落盘（权限 600）
func LoadOrCreate(path string) (*KeyPair, bool, error) {
	if data, err := os.ReadFile(path); err == nil {
		block, _ := pem.Decode(data)
		if block == nil {
			return nil, false, fmt.Errorf("私钥文件格式错误: %s", path)
		}
		key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			return nil, false, err
		}
		rsaKey, ok := key.(*rsa.PrivateKey)
		if !ok {
			return nil, false, fmt.Errorf("私钥类型不是 RSA: %s", path)
		}
		return &KeyPair{Private: rsaKey}, false, nil
	}

	private, err := rsa.GenerateKey(rand.Reader, keyBits)
	if err != nil {
		return nil, false, err
	}
	der, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		return nil, false, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, false, err
	}
	pemData := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if err := os.WriteFile(path, pemData, 0o600); err != nil {
		return nil, false, err
	}
	return &KeyPair{Private: private}, true, nil
}

// PublicKeyBase64 返回公钥（DER / SubjectPublicKeyInfo 的 base64），供客户端内置
func (k *KeyPair) PublicKeyBase64() (string, error) {
	der, err := x509.MarshalPKIXPublicKey(&k.Private.PublicKey)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(der), nil
}

// PublicKeyPKCS1Base64 返回 PKCS#1 格式公钥（base64），
// macOS Security 框架（SecKeyCreateWithData）需要这种格式
func (k *KeyPair) PublicKeyPKCS1Base64() string {
	der := x509.MarshalPKCS1PublicKey(&k.Private.PublicKey)
	return base64.StdEncoding.EncodeToString(der)
}

// Encrypt 用公钥加密 (RSA-OAEP-SHA256)，返回 base64 密文（服务端自测/工具用）
func (k *KeyPair) Encrypt(plain []byte) (string, error) {
	cipher, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &k.Private.PublicKey, plain, nil)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(cipher), nil
}

// EncryptedEnvelope 加密请求信封：encrypted 字段为 base64(RSA-OAEP(明文JSON))
type EncryptedEnvelope struct {
	Encrypted string `json:"encrypted"`
}

// DecryptEnvelope 解开信封并返回明文 JSON
func (k *KeyPair) DecryptEnvelope(body []byte) ([]byte, error) {
	var envelope EncryptedEnvelope
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, fmt.Errorf("解析信封失败: %w", err)
	}
	if envelope.Encrypted == "" {
		return nil, fmt.Errorf("缺少 encrypted 字段")
	}
	cipher, err := base64.StdEncoding.DecodeString(envelope.Encrypted)
	if err != nil {
		return nil, fmt.Errorf("密文 base64 解码失败: %w", err)
	}
	// 优先 OAEP-SHA256（App 使用）；浏览器 JS 库（JSEncrypt）只支持 PKCS#1 v1.5，作为兜底
	if plain, err := rsa.DecryptOAEP(sha256.New(), rand.Reader, k.Private, cipher, nil); err == nil {
		return plain, nil
	}
	if plain, err := rsa.DecryptPKCS1v15(rand.Reader, k.Private, cipher); err == nil {
		return plain, nil
	}
	return nil, fmt.Errorf("解密失败：不支持的填充方式或密钥不匹配")
}

// IsEnvelope 判断请求体是否是加密信封
func IsEnvelope(body []byte) bool {
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(body, &probe); err != nil {
		return false
	}
	_, ok := probe["encrypted"]
	return ok
}
