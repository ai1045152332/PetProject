package service

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"sync"
	"time"
)

// sessionTTL 登录会话有效期
const sessionTTL = 24 * time.Hour

// AuthService 管理后台认证：账号密码登录 + 会话令牌
type AuthService struct {
	mu       sync.Mutex
	username string
	password string
	sessions map[string]time.Time // 会话令牌 → 过期时间
}

// NewAuthService 创建认证服务（password 为空则后台管理全部禁用）
func NewAuthService(username, password string) *AuthService {
	if username == "" {
		username = "admin"
	}
	return &AuthService{
		username: username,
		password: password,
		sessions: make(map[string]time.Time),
	}
}

// Enabled 是否已配置管理密码
func (s *AuthService) Enabled() bool {
	return s.password != ""
}

// CheckPassword 校验登录密码（常量时间比较）
func (s *AuthService) CheckPassword(password string) bool {
	if s.password == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(password), []byte(s.password)) == 1
}

// CheckCredentials 校验账号密码
func (s *AuthService) CheckCredentials(username, password string) bool {
	okUser := subtle.ConstantTimeCompare([]byte(username), []byte(s.username)) == 1
	okPass := s.CheckPassword(password)
	return okUser && okPass
}

// Login 校验账号密码并签发会话令牌
func (s *AuthService) Login(username, password string) (string, time.Time, bool) {
	if !s.CheckCredentials(username, password) {
		return "", time.Time{}, false
	}
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", time.Time{}, false
	}
	token := hex.EncodeToString(buf)
	expiresAt := time.Now().Add(sessionTTL)

	s.mu.Lock()
	s.sessions[token] = expiresAt
	s.mu.Unlock()

	return token, expiresAt, true
}

// Valid 校验会话令牌是否有效（顺带清理过期会话）
func (s *AuthService) Valid(token string) bool {
	if token == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	expiresAt, ok := s.sessions[token]
	if !ok {
		return false
	}
	if time.Now().After(expiresAt) {
		delete(s.sessions, token)
		return false
	}
	return true
}

// Logout 注销会话
func (s *AuthService) Logout(token string) {
	s.mu.Lock()
	delete(s.sessions, token)
	s.mu.Unlock()
}
