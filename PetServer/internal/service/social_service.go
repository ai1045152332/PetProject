// social_service.go 好友与宠物消息业务
// 职责：给设备分配稳定宠物号、维护好友关系、投递/拉取消息（心跳一次性取走）。
package service

import (
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// 宠物号与消息相关的边界常量
const (
	firstPetNo        = int64(100001) // 宠物号起始水位（自增分配，贴近 QQ 早期号段的观感、便于口头传播）
	maxInboxPerDevice = 50            // 每设备待拉取消息上限（超出丢弃最旧的）
	maxMessageRunes   = 200           // 单条消息文本长度上限（按字符计）
)

// 业务错误：控制器据此回给用户可读文案
var (
	ErrSocialInvalidDevice = errors.New("还没获取到你的宠物号，请确认宠物已联网")
	ErrSocialPetNotFound   = errors.New("宠物号不存在（对方尚未激活或从未联网）")
	ErrSocialAddSelf       = errors.New("不能添加自己为好友")
	ErrSocialNotFriend     = errors.New("请先添加对方为好友，再发消息")
	ErrSocialEmptyMessage  = errors.New("消息内容不能为空")
	ErrSocialTooLong       = fmt.Errorf("消息过长（最多 %d 字）", maxMessageRunes)
)

// SocialService 好友与消息服务
type SocialService struct {
	mu    sync.Mutex // 保护「读-改-写」整体状态的一致性
	store *storage.SocialStore
}

// NewSocialService 创建好友与消息服务
func NewSocialService(store *storage.SocialStore) *SocialService {
	return &SocialService{store: store}
}

// validDevice 判断 deviceId 是否可用于好友/消息（排除空与本地占位）
func validSocialDevice(deviceID string) bool {
	return deviceID != "" && deviceID != "unknown-device"
}

// EnsureRegistered 确保设备已注册：新设备分配自增宠物号，刷新展示信息与最近在线时间。
// 返回该设备的宠物号；deviceID 无效时返回 0（该设备暂不参与好友/消息）。
// 心跳每次上报都会调用，设置面板「刷新」也会调用，故宠物号在未心跳时也能即时拿到。
func (s *SocialService) EnsureRegistered(deviceID, hostname, petName string) int64 {
	if !validSocialDevice(deviceID) {
		return 0
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		log.Printf("[social] 读取状态失败(注册): %v", err)
		return 0
	}

	now := time.Now()
	reg, ok := state.Registry[deviceID]
	if !ok {
		state.Counter++
		petNo := firstPetNo + state.Counter - 1
		reg = &model.PetRegistration{
			DeviceID:    deviceID,
			PetNo:       petNo,
			FirstSeenAt: now,
		}
		state.Registry[deviceID] = reg
		log.Printf("[social] 新设备注册，分配宠物号 %d", petNo)
	}
	if petName != "" {
		reg.PetName = petName
	}
	if hostname != "" {
		reg.Hostname = hostname
	}
	reg.LastSeenAt = now

	if err := s.store.Save(state); err != nil {
		log.Printf("[social] 保存状态失败(注册): %v", err)
	}
	return reg.PetNo
}

// AddFriend 给 ownerDeviceID 添加宠物号 petNo 为好友，返回添加后的完整好友列表。
// 已存在则视为成功（幂等）。
func (s *SocialService) AddFriend(ownerDeviceID string, petNo int64) ([]model.FriendEntry, error) {
	if !validSocialDevice(ownerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil, err
	}
	owner, ok := state.Registry[ownerDeviceID]
	if !ok {
		return nil, ErrSocialInvalidDevice
	}
	if owner.PetNo == petNo {
		return nil, ErrSocialAddSelf
	}
	target, ok := findRegByPetNo(state, petNo)
	if !ok {
		return nil, ErrSocialPetNotFound
	}

	for _, f := range state.Friends[ownerDeviceID] {
		if f.PetNo == petNo {
			return cloneFriends(state.Friends[ownerDeviceID]), nil // 幂等：已是好友
		}
	}
	state.Friends[ownerDeviceID] = append(state.Friends[ownerDeviceID], model.FriendEntry{
		PetNo:   target.PetNo,
		PetName: target.PetName,
		AddedAt: time.Now(),
	})
	if err := s.store.Save(state); err != nil {
		return nil, err
	}
	log.Printf("[social] 设备 %s 添加好友 %d(%s)", maskDeviceID(ownerDeviceID), target.PetNo, target.PetName)
	return cloneFriends(state.Friends[ownerDeviceID]), nil
}

// ListFriends 返回某设备的好友列表
func (s *SocialService) ListFriends(ownerDeviceID string) ([]model.FriendEntry, error) {
	if !validSocialDevice(ownerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil, err
	}
	return cloneFriends(state.Friends[ownerDeviceID]), nil
}

// RemoveFriend 删除某设备的一个好友，返回删除后的好友列表
func (s *SocialService) RemoveFriend(ownerDeviceID string, petNo int64) ([]model.FriendEntry, error) {
	if !validSocialDevice(ownerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil, err
	}
	kept := make([]model.FriendEntry, 0, len(state.Friends[ownerDeviceID]))
	for _, f := range state.Friends[ownerDeviceID] {
		if f.PetNo != petNo {
			kept = append(kept, f)
		}
	}
	state.Friends[ownerDeviceID] = kept
	if err := s.store.Save(state); err != nil {
		return nil, err
	}
	return cloneFriends(state.Friends[ownerDeviceID]), nil
}

// SendMessage 由 fromDeviceID 给宠物号 toPetNo 发一条消息，落到对方收件箱等待其心跳拉取。
// 要求发送方已把对方加为好友；接收方离线时消息暂存云端本地。
func (s *SocialService) SendMessage(fromDeviceID string, toPetNo int64, text string) error {
	if !validSocialDevice(fromDeviceID) {
		return ErrSocialInvalidDevice
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return ErrSocialEmptyMessage
	}
	if len([]rune(text)) > maxMessageRunes {
		return ErrSocialTooLong
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return err
	}
	sender, ok := state.Registry[fromDeviceID]
	if !ok {
		return ErrSocialInvalidDevice
	}

	// 好友校验：发送方必须已把对方加为好友
	isFriend := false
	for _, f := range state.Friends[fromDeviceID] {
		if f.PetNo == toPetNo {
			isFriend = true
			break
		}
	}
	if !isFriend {
		return ErrSocialNotFriend
	}
	target, ok := findRegByPetNo(state, toPetNo)
	if !ok {
		return ErrSocialPetNotFound
	}

	msg := model.PetMessage{
		ID:        fmt.Sprintf("%d", time.Now().UnixNano()),
		FromPetNo: sender.PetNo,
		FromName:  sender.PetName,
		Text:      text,
		SentAt:    time.Now(),
	}
	inbox := append(state.Inbox[target.DeviceID], msg)
	if len(inbox) > maxInboxPerDevice { // 超出上限丢弃最旧，保证有界
		inbox = inbox[len(inbox)-maxInboxPerDevice:]
	}
	state.Inbox[target.DeviceID] = inbox

	if err := s.store.Save(state); err != nil {
		return err
	}
	log.Printf("[social] %d → %d 消息已投递（对方下次心跳拉取）", sender.PetNo, target.PetNo)
	return nil
}

// TakePendingMessages 取走某设备的全部待拉取消息（取后即清，作为一次性气泡展示）。
// deviceID 无效或无消息时返回 nil。
func (s *SocialService) TakePendingMessages(deviceID string) []model.PetMessage {
	if !validSocialDevice(deviceID) {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil
	}
	msgs := state.Inbox[deviceID]
	if len(msgs) == 0 {
		return nil
	}
	delete(state.Inbox, deviceID)
	if err := s.store.Save(state); err != nil {
		log.Printf("[social] 保存状态失败(取消息): %v", err)
	}
	return msgs
}

// PetNoFor 只读查询某设备已分配的宠物号；未注册或 deviceID 无效时返回 0。
// 供在线列表展示使用，不触发注册等副作用。
func (s *SocialService) PetNoFor(deviceID string) int64 {
	if !validSocialDevice(deviceID) {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	state, err := s.store.Load()
	if err != nil {
		return 0
	}
	if reg, ok := state.Registry[deviceID]; ok && reg != nil {
		return reg.PetNo
	}
	return 0
}

// findRegByPetNo 按宠物号查注册信息（量级小，直接遍历）
func findRegByPetNo(state model.SocialState, petNo int64) (*model.PetRegistration, bool) {
	for _, r := range state.Registry {
		if r != nil && r.PetNo == petNo {
			return r, true
		}
	}
	return nil, false
}

// cloneFriends 复制好友列表，避免调用方修改内部状态；nil 归一为空切片
func cloneFriends(in []model.FriendEntry) []model.FriendEntry {
	out := make([]model.FriendEntry, len(in))
	copy(out, in)
	return out
}
