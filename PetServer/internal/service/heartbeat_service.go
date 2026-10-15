// Package service 承载 PetServer 的业务逻辑
package service

import (
	"log"
	"sort"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// onlineThreshold 心跳每 1 分钟上报一次，最近 3 分钟内有心跳视为在线
const onlineThreshold = 3 * time.Minute

// HeartbeatService 处理心跳相关业务：登记设备最近心跳
type HeartbeatService struct {
	mu      sync.RWMutex
	devices map[string]model.Device // key: 主机名
	store   *storage.HeartbeatStore
}

// NewHeartbeatService 创建心跳服务实例
func NewHeartbeatService(store *storage.HeartbeatStore) *HeartbeatService {
	return &HeartbeatService{
		devices: make(map[string]model.Device),
		store:   store,
	}
}

// Record 登记一次心跳，返回更新后的设备记录
func (s *HeartbeatService) Record(h model.Heartbeat) model.Device {
	device := model.Device{
		Heartbeat:  h,
		LastSeenAt: time.Now(),
	}

	s.mu.Lock()
	s.devices[h.Hostname] = device
	s.mu.Unlock()

	// 本地持久化失败不影响主流程，仅打日志
	if err := s.store.Append(device); err != nil {
		log.Printf("[heartbeat] 持久化失败: %v", err)
	}

	log.Printf("[heartbeat] %s | version=%s os=%s machine=%s pet=%s state=%s",
		h.Hostname, h.Version, h.OS, h.Machine, h.PetName, h.PetState)

	return device
}

// ListDevices 返回所有登记过的设备（按最近心跳排序暂无必要，保持简单）
func (s *HeartbeatService) ListDevices() []model.Device {
	s.mu.RLock()
	defer s.mu.RUnlock()

	devices := make([]model.Device, 0, len(s.devices))
	for _, d := range s.devices {
		devices = append(devices, d)
	}
	return devices
}

// ListOnlineDevices 返回带在线状态的设备视图，按最近心跳时间倒序（最新的在前）
func (s *HeartbeatService) ListOnlineDevices() []model.DeviceView {
	s.mu.RLock()
	defer s.mu.RUnlock()

	now := time.Now()
	views := make([]model.DeviceView, 0, len(s.devices))
	for _, d := range s.devices {
		since := now.Sub(d.LastSeenAt)
		views = append(views, model.DeviceView{
			Heartbeat:  d.Heartbeat,
			LastSeenAt: d.LastSeenAt.Format(time.RFC3339),
			SecondsAgo: int64(since.Seconds()),
			Online:     since <= onlineThreshold,
		})
	}

	// 距今秒数越小越靠前（即最近心跳优先）
	sort.Slice(views, func(i, j int) bool {
		return views[i].SecondsAgo < views[j].SecondsAgo
	})
	return views
}
