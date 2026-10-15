package service

import (
	"log"
	"strings"

	"petserver/internal/storage"
)

// DeviceNoteService 设备备注：按主机名给设备打备注（如使用人/部门）
type DeviceNoteService struct {
	store *storage.DeviceNoteStore
}

// NewDeviceNoteService 创建设备备注服务
func NewDeviceNoteService(store *storage.DeviceNoteStore) *DeviceNoteService {
	return &DeviceNoteService{store: store}
}

// All 返回全部备注（主机名 → 备注）
func (s *DeviceNoteService) All() map[string]string {
	notes, err := s.store.Load()
	if err != nil {
		log.Printf("[deviceNote] 读取备注失败: %v", err)
		return map[string]string{}
	}
	return notes
}

// Set 设置或清除某主机的备注（空字符串表示清除）
func (s *DeviceNoteService) Set(hostname, note string) error {
	notes, err := s.store.Load()
	if err != nil {
		return err
	}

	note = strings.TrimSpace(note)
	if note == "" {
		delete(notes, hostname)
	} else {
		notes[hostname] = note
	}

	if err := s.store.Save(notes); err != nil {
		return err
	}
	log.Printf("[deviceNote] 已更新备注: %s → %q", hostname, note)
	return nil
}
