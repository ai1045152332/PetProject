package model

// Release App 版本发布信息（由发布脚本生成，落在 dist/latest.json）
type Release struct {
	Version     string `json:"version"`     // 版本号，如 v1.0.002
	File        string `json:"file"`        // 安装包文件名（位于 dist 目录）
	SHA256      string `json:"sha256"`      // 安装包 SHA-256（hex）
	Signature   string `json:"signature"`   // Ed25519 签名（base64，签名对象为 sha256 hex 字符串）
	Notes       string `json:"notes"`       // 更新说明
	PublishedAt string `json:"publishedAt"` // 发布时间（RFC3339）
	Size        int64  `json:"size"`        // 安装包字节数
	MinOS       string `json:"minOS"`       // 最低系统版本，如 13.0
}
