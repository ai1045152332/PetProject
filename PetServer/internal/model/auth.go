package model

import "time"

// AdminSession 管理后台登录会话
type AdminSession struct {
	Token     string    `json:"token"`     // 会话令牌
	ExpiresAt time.Time `json:"expiresAt"` // 过期时间
}
