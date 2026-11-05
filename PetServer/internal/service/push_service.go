package service

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// 推送指令的服务端逻辑：入队、按设备下发（一次性）、列表与删除。
// 指令随心跳下发，客户端执行后不再重投；广播指令按设备去重。
var (
	ErrPushInvalidKind = errors.New("推送类型只能是 update / text / video")
	ErrPushMissingText = errors.New("文字推送必须带内容")
	ErrPushMissingURL  = errors.New("视频推送必须带地址")
)

// maxPushCommands 保留的指令上限（超出丢最旧的），避免文件无限增长
const maxPushCommands = 200

// defaultPushTTL 未指定有效期时的默认存活时长
const defaultPushTTL = 24 * time.Hour

// PushService 推送指令服务
type PushService struct {
	mu    sync.Mutex
	store *storage.PushStore
}

// NewPushService 创建推送服务
func NewPushService(store *storage.PushStore) *PushService {
	return &PushService{store: store}
}

func newPushID() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return hex.EncodeToString([]byte(time.Now().Format(time.RFC3339Nano)))
	}
	return hex.EncodeToString(buf)
}

// Enqueue 新增一条指令；deviceID 为空表示广播
func (s *PushService) Enqueue(cmd model.PushCommand) (model.PushCommand, error) {
	switch cmd.Kind {
	case model.PushKindUpdate:
	case model.PushKindText:
		if cmd.Text == "" {
			return model.PushCommand{}, ErrPushMissingText
		}
	case model.PushKindVideo:
		if cmd.URL == "" {
			return model.PushCommand{}, ErrPushMissingURL
		}
	default:
		return model.PushCommand{}, ErrPushInvalidKind
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	list, err := s.store.Load()
	if err != nil {
		return model.PushCommand{}, err
	}
	now := time.Now()
	cmd.ID = newPushID()
	cmd.CreatedAt = now
	if cmd.ExpiresAt.IsZero() {
		cmd.ExpiresAt = now.Add(defaultPushTTL)
	}
	cmd.DeliveredTo = nil
	list = append(list, cmd)
	if len(list) > maxPushCommands {
		list = list[len(list)-maxPushCommands:]
	}
	if err := s.store.Save(list); err != nil {
		return model.PushCommand{}, err
	}
	return cmd, nil
}

// PendingFor 取该设备应执行、且尚未执行过的指令，并登记为已下发。
func (s *PushService) PendingFor(deviceID string) []model.PushCommand {
	if deviceID == "" {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	list, err := s.store.Load()
	if err != nil {
		return nil
	}
	now := time.Now()
	out := make([]model.PushCommand, 0, 2)
	changed := false
	for i := range list {
		cmd := &list[i]
		if cmd.Expired(now) || cmd.Delivered(deviceID) {
			continue
		}
		if cmd.DeviceID != "" && cmd.DeviceID != deviceID {
			continue
		}
		out = append(out, *cmd)
		cmd.DeliveredTo = append(cmd.DeliveredTo, deviceID)
		changed = true
	}
	if changed {
		// 顺手丢掉过期一周以上的指令，避免文件越滚越大
		kept := list[:0]
		for _, cmd := range list {
			if !cmd.ExpiresAt.IsZero() && now.Sub(cmd.ExpiresAt) > 7*24*time.Hour {
				continue
			}
			kept = append(kept, cmd)
		}
		_ = s.store.Save(kept)
	}
	return out
}

// List 全部指令（新 → 旧），供后台查看
func (s *PushService) List() []model.PushCommand {
	s.mu.Lock()
	defer s.mu.Unlock()

	list, err := s.store.Load()
	if err != nil {
		return []model.PushCommand{}
	}
	out := make([]model.PushCommand, 0, len(list))
	for i := len(list) - 1; i >= 0; i-- {
		out = append(out, list[i])
	}
	return out
}

// Delete 删除一条指令
func (s *PushService) Delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	list, err := s.store.Load()
	if err != nil {
		return err
	}
	kept := list[:0]
	for _, cmd := range list {
		if cmd.ID != id {
			kept = append(kept, cmd)
		}
	}
	return s.store.Save(kept)
}
