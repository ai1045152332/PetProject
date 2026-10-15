package service

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// sessionTTL 登录会话有效期
const sessionTTL = 24 * time.Hour

// AuthService 管理后台认证：账号密码登录 + 会话令牌
type AuthService struct {
	mu        sync.Mutex
	username  string
	password  string
	sessions  map[string]time.Time // 会话令牌 → 过期时间
	storePath string               // 会话持久化文件（服务重启/重新部署后登录态不丢）
}

// NewAuthService 创建认证服务（password 为空则后台管理全部禁用）
// storePath 为空则不持久化（仅内存）
func NewAuthService(username, password, storePath string) *AuthService {
	if username == "" {
		username = "admin"
	}
	svc := &AuthService{
		username:  username,
		password:  password,
		sessions:  make(map[string]time.Time),
		storePath: storePath,
	}
	svc.loadSessions()
	return svc
}

// loadSessions 从磁盘恢复会话并清理已过期项
func (s *AuthService) loadSessions() {
	if s.storePath == "" {
		return
	}
	data, err := os.ReadFile(s.storePath)
	if err != nil {
		return
	}
	stored := map[string]time.Time{}
	if err := json.Unmarshal(data, &stored); err != nil {
		log.Printf("[auth] 会话文件解析失败，忽略: %v", err)
		return
	}
	now := time.Now()
	kept := 0
	for token, expiresAt := range stored {
		if now.Before(expiresAt) {
			s.sessions[token] = expiresAt
			kept++
		}
	}
	if kept > 0 {
		log.Printf("[auth] 已恢复 %d 个登录会话（重启不丢登录态）", kept)
	}
	s.saveSessionsLocked()
}

// saveSessionsLocked 落盘（调用方需保证不重入，或由内部加锁）
func (s *AuthService) saveSessionsLocked() {
	if s.storePath == "" {
		return
	}
	s.mu.Lock()
	snapshot := make(map[string]time.Time, len(s.sessions))
	for k, v := range s.sessions {
		snapshot[k] = v
	}
	s.mu.Unlock()

	data, err := json.MarshalIndent(snapshot, "", "  ")
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(s.storePath), 0o700); err != nil {
		log.Printf("[auth] 创建会话目录失败: %v", err)
		return
	}
	tmp := s.storePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		log.Printf("[auth] 保存会话失败: %v", err)
		return
	}
	if err := os.Rename(tmp, s.storePath); err != nil {
		log.Printf("[auth] 更新会话文件失败: %v", err)
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
	s.saveSessionsLocked()

	return token, expiresAt, true
}

// Valid 校验会话令牌是否有效（顺带清理过期会话）
func (s *AuthService) Valid(token string) bool {
	if token == "" {
		return false
	}

	s.mu.Lock()
	expiresAt, ok := s.sessions[token]
	if !ok {
		s.mu.Unlock()
		return false
	}
	if time.Now().After(expiresAt) {
		delete(s.sessions, token)
		s.mu.Unlock()
		s.saveSessionsLocked()
		return false
	}
	s.mu.Unlock()
	return true
}

// Logout 注销会话
func (s *AuthService) Logout(token string) {
	s.mu.Lock()
	delete(s.sessions, token)
	s.mu.Unlock()
	s.saveSessionsLocked()
}
