// Package storage 负责心跳数据的本地持久化
package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"petserver/internal/model"
)

// HeartbeatStore 以 JSON Lines 格式把心跳追加到本地文件（一行一条）
type HeartbeatStore struct {
	mu   sync.Mutex
	file *os.File
}

// NewHeartbeatStore 打开（不存在则创建）持久化文件
func NewHeartbeatStore(path string) (*HeartbeatStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	return &HeartbeatStore{file: file}, nil
}

// Append 追加一条设备心跳记录
func (s *HeartbeatStore) Append(device model.Device) error {
	line, err := json.Marshal(device)
	if err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = s.file.Write(append(line, '\n'))
	return err
}

// Close 关闭底层文件
func (s *HeartbeatStore) Close() error {
	return s.file.Close()
}
