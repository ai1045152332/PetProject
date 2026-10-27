// social_store.go 好友与宠物消息的本地持久化
// 单 JSON 文件整体读写（量级小、开销可忽略），沿用仓库内先写临时文件再 rename 的原子替换写法。
package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"

	"petserver/internal/model"
)

// SocialStore 好友与消息状态存储
type SocialStore struct {
	mu   sync.Mutex
	path string
}

// NewSocialStore 创建存储（确保目录存在；文件不存在时视为空库）
func NewSocialStore(path string) (*SocialStore, error) {
	if dir := filepath.Dir(path); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	return &SocialStore{path: path}, nil
}

// Load 读取整体状态；文件不存在或为空时返回各 map 已初始化的空状态
func (s *SocialStore) Load() (model.SocialState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	state := newEmptySocialState()
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return state, nil
	}
	if err != nil {
		return state, err
	}
	if err := json.Unmarshal(data, &state); err != nil {
		return newEmptySocialState(), err
	}
	// 兼容旧文件缺字段：反序列化后仍可能为 nil
	if state.Registry == nil {
		state.Registry = map[string]*model.PetRegistration{}
	}
	if state.Friends == nil {
		state.Friends = map[string][]model.FriendEntry{}
	}
	if state.Inbox == nil {
		state.Inbox = map[string][]model.PetMessage{}
	}
	if state.Delivered == nil {
		state.Delivered = map[string]map[string]model.DeliveredMessage{}
	}
	if state.Requests == nil {
		state.Requests = map[string]*model.FriendRequest{}
	}
	if state.History == nil {
		state.History = []model.PetConversationRecord{}
	}
	return state, nil
}

// Save 全量写回（临时文件 + rename 原子替换，避免写一半损坏）
func (s *SocialStore) Save(state model.SocialState) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if state.Registry == nil {
		state.Registry = map[string]*model.PetRegistration{}
	}
	if state.Friends == nil {
		state.Friends = map[string][]model.FriendEntry{}
	}
	if state.Inbox == nil {
		state.Inbox = map[string][]model.PetMessage{}
	}
	if state.Delivered == nil {
		state.Delivered = map[string]map[string]model.DeliveredMessage{}
	}
	if state.Requests == nil {
		state.Requests = map[string]*model.FriendRequest{}
	}
	if state.History == nil {
		state.History = []model.PetConversationRecord{}
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// newEmptySocialState 返回各 map 均已初始化的空状态
func newEmptySocialState() model.SocialState {
	return model.SocialState{
		Registry:  map[string]*model.PetRegistration{},
		Friends:   map[string][]model.FriendEntry{},
		Inbox:     map[string][]model.PetMessage{},
		Delivered: map[string]map[string]model.DeliveredMessage{},
		Requests:  map[string]*model.FriendRequest{},
		History:   []model.PetConversationRecord{},
	}
}
