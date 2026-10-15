package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"petserver/internal/model"
)

// ActivationStore 激活码的本地持久化（全量 JSON 文件，码量小，读写开销可忽略）
type ActivationStore struct {
	mu   sync.Mutex
	path string
}

// NewActivationStore 创建激活码存储（文件不存在时视为空库）
func NewActivationStore(path string) (*ActivationStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return &ActivationStore{path: path}, nil
}

// Load 读取全部激活码
func (s *ActivationStore) Load() ([]model.ActivationCode, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var codes []model.ActivationCode
	if err := json.Unmarshal(data, &codes); err != nil {
		return nil, err
	}
	return codes, nil
}

// Save 全量写回激活码（先写临时文件再改名，避免写一半损坏）
func (s *ActivationStore) Save(codes []model.ActivationCode) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := json.MarshalIndent(codes, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
