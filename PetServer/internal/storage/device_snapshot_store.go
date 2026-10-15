package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"petserver/internal/model"
)

// deviceSnapshotRetention 快照中设备的保留时长（超过则视为长期未上报，加载时丢弃）
const deviceSnapshotRetention = 30 * 24 * time.Hour

// DeviceSnapshotStore 设备快照：按主机名保存每台设备最后一次心跳，
// 让设备列表在服务重启/重新部署后立即恢复（内存列表本身是易失的）
type DeviceSnapshotStore struct {
	mu   sync.Mutex
	path string
}

// NewDeviceSnapshotStore 创建设备快照存储
func NewDeviceSnapshotStore(path string) (*DeviceSnapshotStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return &DeviceSnapshotStore{path: path}, nil
}

// Load 读取快照（丢弃超过保留期的设备）
func (s *DeviceSnapshotStore) Load() (map[string]model.Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return map[string]model.Device{}, nil
	}
	if err != nil {
		return nil, err
	}

	devices := map[string]model.Device{}
	if err := json.Unmarshal(data, &devices); err != nil {
		return nil, err
	}

	cutoff := time.Now().Add(-deviceSnapshotRetention)
	for hostname, d := range devices {
		if d.LastSeenAt.Before(cutoff) {
			delete(devices, hostname)
		}
	}
	return devices, nil
}

// Save 全量写回快照（临时文件 + rename 原子替换，避免写坏）
func (s *DeviceSnapshotStore) Save(devices map[string]model.Device) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := json.MarshalIndent(devices, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
