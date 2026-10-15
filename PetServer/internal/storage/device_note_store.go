package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// DeviceNoteStore 设备备注持久化（主机名 → 备注）
type DeviceNoteStore struct {
	mu   sync.Mutex
	path string
}

// NewDeviceNoteStore 创建设备备注存储
func NewDeviceNoteStore(path string) (*DeviceNoteStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return &DeviceNoteStore{path: path}, nil
}

// Load 读取全部备注
func (s *DeviceNoteStore) Load() (map[string]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	notes := map[string]string{}
	if err := json.Unmarshal(data, &notes); err != nil {
		return nil, err
	}
	return notes, nil
}

// Save 全量写回
func (s *DeviceNoteStore) Save(notes map[string]string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := json.MarshalIndent(notes, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
