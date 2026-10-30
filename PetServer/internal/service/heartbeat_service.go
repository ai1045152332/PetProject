// Package service 承载 PetServer 的业务逻辑
package service

import (
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// onlineThreshold 心跳每 1 分钟上报一次，最近 3 分钟内有心跳视为在线
const onlineThreshold = 3 * time.Minute

// HeartbeatService 处理心跳相关业务：登记设备最近心跳
type HeartbeatService struct {
	mu       sync.RWMutex
	devices  map[string]model.Device // key: 设备 ID（见 deviceKey）；缺 deviceId 的老客户端退回主机名
	store    *storage.HeartbeatStore
	snapshot *storage.DeviceSnapshotStore // 设备快照：重启后恢复列表
}

// deviceKey 设备身份键：以 deviceId 为准，缺失时退回主机名。
// 宠物号在好友体系里按 deviceId 唯一分配，设备列表若按主机名做键，
// 同一台机器换个主机名大小写（或改 LocalHostName）就会被当成两台设备、重复展示同一个宠物号。
func deviceKey(d model.Device) string {
	if id := strings.TrimSpace(d.DeviceID); id != "" {
		return strings.ToLower(id)
	}
	return strings.ToLower(strings.TrimSpace(d.Hostname))
}

// NewHeartbeatService 创建心跳服务实例，并从快照恢复已知设备
// （内存列表是易失的，重启/重新部署后靠快照立即恢复，无需等设备重新上报）
func NewHeartbeatService(store *storage.HeartbeatStore, snapshot *storage.DeviceSnapshotStore) *HeartbeatService {
	svc := &HeartbeatService{
		devices:  make(map[string]model.Device),
		store:    store,
		snapshot: snapshot,
	}
	svc.restoreFromSnapshot()
	return svc
}

// restoreFromSnapshot 启动时恢复设备列表
func (s *HeartbeatService) restoreFromSnapshot() {
	if s.snapshot == nil {
		return
	}
	devices, err := s.snapshot.Load()
	if err != nil {
		log.Printf("[heartbeat] 设备快照读取失败，忽略: %v", err)
		return
	}
	migrated := 0
	for hostname, d := range devices {
		// 旧快照以主机名为 key，加载时按 deviceKey 重新归并，一次重启即完成迁移；
		// 同一 deviceId 出现多条时保留最近一次心跳（map 遍历无序，不能靠覆盖顺序）
		key := deviceKey(d)
		if existing, ok := s.devices[key]; ok && !d.LastSeenAt.After(existing.LastSeenAt) {
			migrated++
			continue
		}
		s.devices[key] = d
		if key != hostname {
			migrated++
		}
	}
	if len(devices) > 0 {
		log.Printf("[heartbeat] 已从快照恢复 %d 台设备（重启不丢设备列表）", len(s.devices))
	}
	if migrated > 0 {
		log.Printf("[heartbeat] 快照 %d 条旧记录已按 deviceId 归并", migrated)
	}
}

// persistSnapshot 保存设备快照（写失败不影响主流程）
func (s *HeartbeatService) persistSnapshot() {
	if s.snapshot == nil {
		return
	}
	s.mu.RLock()
	snapshotCopy := make(map[string]model.Device, len(s.devices))
	for k, v := range s.devices {
		snapshotCopy[k] = v
	}
	s.mu.RUnlock()

	if err := s.snapshot.Save(snapshotCopy); err != nil {
		log.Printf("[heartbeat] 设备快照保存失败: %v", err)
	}
}

// Record 登记一次心跳，返回更新后的设备记录
func (s *HeartbeatService) Record(h model.Heartbeat) model.Device {
	device := model.Device{
		Heartbeat:  h,
		LastSeenAt: time.Now(),
	}

	s.mu.Lock()
	s.devices[deviceKey(device)] = device
	s.mu.Unlock()

	// 本地持久化失败不影响主流程，仅打日志
	if err := s.store.Append(device); err != nil {
		log.Printf("[heartbeat] 持久化失败: %v", err)
	}
	// 更新设备快照（重启后设备列表不丢）
	s.persistSnapshot()

	log.Printf("[heartbeat] %s | version=%s os=%s machine=%s pet=%s state=%s",
		h.Hostname, h.Version, h.OS, h.Machine, h.PetName, h.PetState)

	return device
}

// Remove 删除一台设备记录（内存 + 快照），返回是否真的删掉。
// 优先按 deviceId 匹配，兼容按主机名（大小写不敏感）删除。
// 注意：设备若仍在运行，下一次心跳（约 1 分钟内）会重新登记它；
// 删除主要用于清理长期离线/换机的残留记录
func (s *HeartbeatService) Remove(deviceOrHost string) bool {
	target := strings.TrimSpace(deviceOrHost)
	if target == "" {
		return false
	}

	s.mu.Lock()
	delKey := ""
	if _, ok := s.devices[strings.ToLower(target)]; ok {
		delKey = strings.ToLower(target)
	} else {
		for k, d := range s.devices {
			if strings.EqualFold(d.Hostname, target) {
				delKey = k
				break
			}
		}
	}
	if delKey == "" {
		s.mu.Unlock()
		return false
	}
	delete(s.devices, delKey)
	s.mu.Unlock()

	s.persistSnapshot()
	log.Printf("[heartbeat] 已删除设备记录: %s", target)
	return true
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
