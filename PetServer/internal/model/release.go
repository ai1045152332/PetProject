package model

// Release App 版本发布信息（由发布脚本生成，落在 dist/latest.json）
// File/SHA256/Signature/Size 始终指向 zip：客户端自动更新只认这几个字段
// DmgXxx 为官网手动安装用的 dmg，旧客户端忽略
type Release struct {
	Version     string `json:"version"`     // 版本号，如 v1.0.002
	File        string `json:"file"`        // 自动更新包文件名（zip，位于 dist 目录）
	SHA256      string `json:"sha256"`      // 安装包 SHA-256（hex）
	Signature   string `json:"signature"`   // Ed25519 签名（base64，签名对象为 sha256 hex 字符串）
	Notes       string `json:"notes"`       // 更新说明
	PublishedAt string `json:"publishedAt"` // 发布时间（RFC3339）
	Size        int64  `json:"size"`        // 安装包字节数
	MinOS       string `json:"minOS"`       // 最低系统版本，如 13.0

	DmgFile      string `json:"dmgFile,omitempty"`      // 官网下载的 dmg 文件名
	DmgSHA256    string `json:"dmgSHA256,omitempty"`    // dmg SHA-256（hex）
	DmgSignature string `json:"dmgSignature,omitempty"` // dmg 的 Ed25519 签名（base64）
	DmgSize      int64  `json:"dmgSize,omitempty"`      // dmg 字节数
}
