package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"petserver/internal/model"
)

// PushStore 推送指令的本地持久化（JSON 全量文件，指令量小）
type PushStore struct {
	mu   sync.Mutex
	path string
}

// NewPushStore 创建推送存储（文件不存在时视为空）
func NewPushStore(path string) (*PushStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return &PushStore{path: path}, nil
}

// Load 读取全部指令（旧 → 新）
func (s *PushStore) Load() ([]model.PushCommand, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var list []model.PushCommand
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, err
	}
	return list, nil
}

// Save 全量写回（先写临时文件再改名，避免写一半损坏）
func (s *PushStore) Save(list []model.PushCommand) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
