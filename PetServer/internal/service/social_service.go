// social_service.go 好友与宠物消息业务
// 职责：给设备分配稳定宠物号、维护好友关系（加好友需对方同意，同意后双向互加）、
// 投递/拉取消息（心跳一次性取走，接收端看完关卡后确认已读供后台留痕）。
package service

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// 宠物号、消息与好友申请相关的边界常量
const (
	firstPetNo        = int64(100001)    // 宠物号起始水位（自增分配，贴近 QQ 早期号段的观感、便于口头传播）
	maxInboxPerDevice = 50               // 每设备待拉取/待确认消息上限（超出丢弃最旧的）
	maxMessageRunes   = 200              // 单条消息文本长度上限（按字符计）
	maxHistoryRecords = 1000             // 对话留痕全局上限（超出丢弃最旧的，供后台查看）
	maxPendingReqs    = 20               // 全局待处理好友申请上限（超出丢弃最旧的）
	redeliverAfter    = 10 * time.Minute // 已下发但未确认已读的重投间隔（跟着心跳节奏走）
	maxDeliverTimes   = 3                // 同一条消息最多下发次数（避免无限弹卡）
	deliveredTTL      = 24 * time.Hour   // 超过这个年龄的未读消息不再重投（留痕仍保留）
)

// 业务错误：控制器据此回给用户可读文案
var (
	ErrSocialInvalidDevice = errors.New("还没获取到你的宠物号，请确认宠物已联网")
	ErrSocialPetNotFound   = errors.New("宠物号不存在（对方尚未激活或从未联网）")
	ErrSocialAddSelf       = errors.New("不能添加自己为好友")
	ErrSocialNotFriend     = errors.New("请先添加对方为好友，再发消息")
	ErrSocialEmptyMessage  = errors.New("消息内容不能为空")
	ErrSocialTooLong       = fmt.Errorf("消息过长（最多 %d 字）", maxMessageRunes)
	ErrSocialNoRequest     = errors.New("没有找到待处理的好友申请（可能已处理或过期）")
)

// 好友申请的两种结果：pending 等对方同意，mutual 双方已是好友
const (
	FriendRequestPending = "pending" // 申请已发出，等对方同意
	FriendRequestMutual  = "mutual"  // 对方也申请过，已直接双向成为好友
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

// RequestFriend 发起加好友申请：ownerDeviceID 申请添加宠物号 petNo 为好友。
// 需对方同意后双方才互为好友；若对方已申请过本设备，则视为同意，直接双向互加。
// 已是好友时幂等返回 FriendRequestMutual。
func (s *SocialService) RequestFriend(ownerDeviceID string, petNo int64) ([]model.FriendEntry, string, error) {
	if !validSocialDevice(ownerDeviceID) {
		return nil, "", ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil, "", err
	}
	owner, ok := state.Registry[ownerDeviceID]
	if !ok {
		return nil, "", ErrSocialInvalidDevice
	}
	if owner.PetNo == petNo {
		return nil, "", ErrSocialAddSelf
	}
	target, ok := findRegByPetNo(state, petNo)
	if !ok {
		return nil, "", ErrSocialPetNotFound
	}

	// 双向已是好友：幂等成功，不重复发申请
	if isFriendOf(state, ownerDeviceID, petNo) && isFriendOf(state, target.DeviceID, owner.PetNo) {
		return cloneFriends(state.Friends[ownerDeviceID]), FriendRequestMutual, nil
	}

	// 对向申请待处理（对方也加过我方）：本次视为互相同意，直接双向互加
	if _, req, ok := findPendingRequest(state, owner.PetNo, target.DeviceID, 0); ok {
		delete(state.Requests, req.FromDevice)
		markHistoryStatus(state, req.ID, "accepted", time.Now())
		addMutualFriendship(state, owner, target)
		if err := s.store.Save(state); err != nil {
			return nil, "", err
		}
		log.Printf("[social] 双向申请自动成为好友：%d(%s) ↔ %d(%s)", owner.PetNo, owner.PetName, target.PetNo, target.PetName)
		return cloneFriends(state.Friends[ownerDeviceID]), FriendRequestMutual, nil
	}

	// 已有相同方向的待处理申请：幂等，不重复发
	if _, _, ok := findPendingRequest(state, target.PetNo, ownerDeviceID, 0); !ok {
		req := &model.FriendRequest{
			ID:         newSocialID(),
			FromDevice: ownerDeviceID,
			FromPetNo:  owner.PetNo,
			FromName:   owner.PetName,
			ToPetNo:    target.PetNo,
			CreatedAt:  time.Now(),
		}
		state.Requests[ownerDeviceID] = req
		state.History = appendHistory(state.History, model.PetConversationRecord{
			Kind:       model.ConversationKindRequest,
			FromPetNo:  owner.PetNo,
			FromName:   owner.PetName,
			FromHost:   owner.Hostname,
			ToPetNo:    target.PetNo,
			ToName:     target.PetName,
			ToHost:     target.Hostname,
			ToDeviceID: target.DeviceID,
			IDs:        []string{req.ID},
			Status:     "pending",
			Text:       fmt.Sprintf("%s(#%d) 申请加你为好友", owner.PetName, owner.PetNo),
			SentAt:     req.CreatedAt,
		})
		trimPendingRequests(state)
	}

	if err := s.store.Save(state); err != nil {
		return nil, "", err
	}
	log.Printf("[social] 设备 %s 向 %d(%s) 发起好友申请（待对方同意）", maskDeviceID(ownerDeviceID), target.PetNo, target.PetName)
	return cloneFriends(state.Friends[ownerDeviceID]), FriendRequestPending, nil
}

// PendingRequests 拉取发给某设备的全部待处理好友申请（只读：不清除，直到对方同意/拒绝）。
// 客户端据此弹卡与在设置面板列待办，重复下发靠本地已展示 ID 去重。结果按发起时间旧 → 新。
func (s *SocialService) PendingRequests(deviceID string) []model.FriendRequest {
	if !validSocialDevice(deviceID) {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil
	}
	self, ok := state.Registry[deviceID]
	if !ok {
		return nil
	}
	var out []model.FriendRequest
	for _, req := range state.Requests {
		if req == nil {
			continue
		}
		if req.ToPetNo != self.PetNo || req.FromDevice == deviceID {
			continue // 只收发给自己的申请
		}
		out = append(out, *req)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out
}

// AcceptFriendRequest 同意发给本设备的好友申请：同意后双方互为好友，返回本设备的好友列表。
func (s *SocialService) AcceptFriendRequest(handlerDeviceID string, fromPetNo int64) ([]model.FriendEntry, error) {
	return s.handleFriendRequest(handlerDeviceID, fromPetNo, "accepted")
}

// RejectFriendRequest 拒绝对方的好友申请（不建立好友关系）。
func (s *SocialService) RejectFriendRequest(handlerDeviceID string, fromPetNo int64) ([]model.FriendEntry, error) {
	return s.handleFriendRequest(handlerDeviceID, fromPetNo, "rejected")
}

// handleFriendRequest 同意/拒绝的共用处理：定位待处理申请，仅同意时双向互加
func (s *SocialService) handleFriendRequest(handlerDeviceID string, fromPetNo int64, status string) ([]model.FriendEntry, error) {
	if !validSocialDevice(handlerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil, err
	}
	handler, ok := state.Registry[handlerDeviceID]
	if !ok {
		return nil, ErrSocialInvalidDevice
	}
	requesterDev, req, ok := findPendingRequest(state, handler.PetNo, "", fromPetNo)
	if !ok {
		return nil, ErrSocialNoRequest
	}

	now := time.Now()
	markHistoryStatus(state, req.ID, status, now)
	delete(state.Requests, requesterDev) // 处理完的申请不再占位（结果已落留痕）

	if status == "accepted" {
		requester, ok := state.Registry[requesterDev]
		if !ok {
			return nil, ErrSocialPetNotFound
		}
		addMutualFriendship(state, handler, requester)
	}

	if err := s.store.Save(state); err != nil {
		return nil, err
	}
	log.Printf("[social] 设备 %s %s 了 %d 的好友申请", maskDeviceID(handlerDeviceID), status, fromPetNo)
	return cloneFriends(state.Friends[handlerDeviceID]), nil
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

// RemoveFriend 删除好友：同意后是双向关系，删除也双向解除，并清掉双方间的待处理申请。
// 返回删除后的好友列表。
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
	ok := state.Registry[ownerDeviceID] != nil
	state.Friends[ownerDeviceID] = filterFriends(state.Friends[ownerDeviceID], petNo)
	if target, found := findRegByPetNo(state, petNo); found {
		state.Friends[target.DeviceID] = filterFriends(state.Friends[target.DeviceID], ownerPetNo(state.Registry[ownerDeviceID]))
		clearRequestsBetween(state, ownerDeviceID, target.DeviceID)
	}
	if err := s.store.Save(state); err != nil {
		return nil, err
	}
	if ok {
		log.Printf("[social] 设备 %s 删除好友 %d（双向解除）", maskDeviceID(ownerDeviceID), petNo)
	}
	return cloneFriends(state.Friends[ownerDeviceID]), nil
}

// SendMessage 由 fromDeviceID 给宠物号 toPetNo 发一条消息，落到对方收件箱等待其心跳拉取。
// 要求双方已互加好友（需对方同意过）；接收方离线时消息暂存云端本地。
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
	target, ok := findRegByPetNo(state, toPetNo)
	if !ok {
		return ErrSocialPetNotFound
	}
	// 好友校验：双方都在彼此好友列表里才允许发（同意后的互加状态）
	if !isFriendOf(state, fromDeviceID, toPetNo) || !isFriendOf(state, target.DeviceID, sender.PetNo) {
		return ErrSocialNotFriend
	}

	now := time.Now()
	msg := model.PetMessage{
		ID:        newSocialID(),
		FromPetNo: sender.PetNo,
		FromName:  sender.PetName,
		Text:      text,
		SentAt:    now,
	}
	inbox := append(state.Inbox[target.DeviceID], msg)
	if len(inbox) > maxInboxPerDevice { // 超出上限丢弃最旧，保证有界
		inbox = inbox[len(inbox)-maxInboxPerDevice:]
	}
	state.Inbox[target.DeviceID] = inbox

	// 对话留痕：这里持久保留一份供管理后台查看好友间对话，
	// 并记下消息 ID 以便接收端关卡时回填下发/已读时间
	state.History = appendHistory(state.History, model.PetConversationRecord{
		Kind:       model.ConversationKindMessage,
		FromPetNo:  sender.PetNo,
		FromName:   sender.PetName,
		FromHost:   sender.Hostname,
		ToPetNo:    target.PetNo,
		ToName:     target.PetName,
		ToHost:     target.Hostname,
		ToDeviceID: target.DeviceID,
		IDs:        []string{msg.ID},
		Text:       text,
		SentAt:     now,
	})

	if err := s.store.Save(state); err != nil {
		return err
	}
	log.Printf("[social] %d → %d 消息已投递（对方下次心跳拉取）", sender.PetNo, target.PetNo)
	return nil
}

// PeekPendingMessages 只读预览某设备待展示消息：收件箱里从未下发过的，加上到点该重投的。
// 不改动状态，供心跳先下发、确认deviceId 有效后再登记下发时间。
func (s *SocialService) PeekPendingMessages(deviceID string) []model.PetMessage {
	if !validSocialDevice(deviceID) {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return nil
	}
	return pendingMessages(state, deviceID, time.Now())
}

// DeliverMessages 登记这批消息为「已下发、待确认已读」：收件箱保留原样，
// 只有接收端看完关卡调 MarkMessagesRead 才真正清除，避免没看完就退出把消息丢在云端。
func (s *SocialService) DeliverMessages(deviceID string, msgs []model.PetMessage) {
	if !validSocialDevice(deviceID) || len(msgs) == 0 {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return
	}
	if state.Delivered[deviceID] == nil {
		state.Delivered[deviceID] = map[string]model.DeliveredMessage{}
	}
	now := time.Now()
	for _, msg := range msgs {
		d := state.Delivered[deviceID][msg.ID]
		d.Message, d.DeliveredAt, d.Times = msg, now, d.Times+1
		state.Delivered[deviceID][msg.ID] = d
	}
	if len(state.Delivered[deviceID]) > maxInboxPerDevice { // 长期未确认时丢弃最早下发的，保证有界
		state.Delivered[deviceID] = dropOldestDelivered(state.Delivered[deviceID], maxInboxPerDevice)
	}
	markHistoryDelivered(state, deviceID, msgs, now)

	if err := s.store.Save(state); err != nil {
		log.Printf("[social] 保存状态失败(登记下发): %v", err)
	}
}

// MarkMessagesRead 由接收端（看完消息并关卡时）确认已读：
// 从收件箱与「已下发」名单中清除这些 ID，并把对应对话留痕标上已读时间，
// 让后台能看到对方到底有没有读过。返回实际命中的留痕条数。
func (s *SocialService) MarkMessagesRead(deviceID string, ids []string) (int, error) {
	if !validSocialDevice(deviceID) {
		return 0, ErrSocialInvalidDevice
	}
	wanted := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		if id != "" {
			wanted[id] = struct{}{}
		}
	}
	if len(wanted) == 0 {
		return 0, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return 0, err
	}

	kept := make([]model.PetMessage, 0, len(state.Inbox[deviceID]))
	for _, msg := range state.Inbox[deviceID] {
		if _, hit := wanted[msg.ID]; !hit {
			kept = append(kept, msg)
		}
	}
	if len(kept) == 0 {
		delete(state.Inbox, deviceID)
	} else {
		state.Inbox[deviceID] = kept
	}
	for id := range wanted {
		delete(state.Delivered[deviceID], id)
	}
	if len(state.Delivered[deviceID]) == 0 {
		delete(state.Delivered, deviceID)
	}

	hit := markHistoryRead(state, deviceID, wanted, time.Now())
	if err := s.store.Save(state); err != nil {
		return 0, err
	}
	log.Printf("[social] 设备 %s 确认已读 %d 条消息", maskDeviceID(deviceID), hit)
	return hit, nil
}

// pendingMessages 汇总该设备本次应下发的消息：从未下发过的 + 过了重投间隔仍未确认的。
// 超过保留龄或下发次数达上限的没有继续打扰的必要，不再下发（留痕仍在，后台可查未读）。
func pendingMessages(state model.SocialState, deviceID string, now time.Time) []model.PetMessage {
	var out []model.PetMessage
	for _, msg := range state.Inbox[deviceID] {
		d, seen := state.Delivered[deviceID][msg.ID]
		switch {
		case !seen:
			out = append(out, msg) // 首次下发
		case now.Sub(msg.SentAt) > deliveredTTL, d.Times >= maxDeliverTimes:
			// 没人看或已打扰到位，不再弹卡
		case now.Sub(d.DeliveredAt) >= redeliverAfter:
			out = append(out, msg) // 到点重投
		}
	}
	return out
}

// dropOldestDelivered 按下发时间保留最近 limit 条，丢弃更早的占位
func dropOldestDelivered(in map[string]model.DeliveredMessage, limit int) map[string]model.DeliveredMessage {
	if len(in) <= limit {
		return in
	}
	all := make([]model.DeliveredMessage, 0, len(in))
	for _, d := range in {
		all = append(all, d)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].DeliveredAt.After(all[j].DeliveredAt) })

	out := make(map[string]model.DeliveredMessage, limit)
	for _, d := range all[:limit] {
		out[d.Message.ID] = d
	}
	return out
}

// Conversations 返回全部对话留痕（旧 → 新），供管理后台展示；无记录时返回空切片。
func (s *SocialService) Conversations() []model.PetConversationRecord {
	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		log.Printf("[social] 读取状态失败(对话记录): %v", err)
		return []model.PetConversationRecord{}
	}
	out := make([]model.PetConversationRecord, len(state.History))
	copy(out, state.History)
	return out
}

// ClearConversations 清空全部对话留痕（管理后台维护用）。
func (s *SocialService) ClearConversations() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	state, err := s.store.Load()
	if err != nil {
		return err
	}
	state.History = []model.PetConversationRecord{}
	if err := s.store.Save(state); err != nil {
		return err
	}
	log.Printf("[social] 对话记录已清空")
	return nil
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

// isFriendOf 某设备好友列表中是否有该宠物号
func isFriendOf(state model.SocialState, deviceID string, petNo int64) bool {
	for _, f := range state.Friends[deviceID] {
		if f.PetNo == petNo {
			return true
		}
	}
	return false
}

// filterFriends 去掉列表中指定宠物号的条目
func filterFriends(in []model.FriendEntry, petNo int64) []model.FriendEntry {
	kept := make([]model.FriendEntry, 0, len(in))
	for _, f := range in {
		if f.PetNo != petNo {
			kept = append(kept, f)
		}
	}
	return kept
}

// ownerPetNo 取注册信息的宠物号；未注册时返回 0（只能匹配到无效好友号）
func ownerPetNo(reg *model.PetRegistration) int64 {
	if reg == nil {
		return 0
	}
	return reg.PetNo
}

// addMutualFriendship 双向互加：双方好友列表各补上对方（已有则不重复）
func addMutualFriendship(state model.SocialState, a, b *model.PetRegistration) {
	now := time.Now()
	for _, pair := range []struct {
		deviceID    string
		self, other *model.PetRegistration
	}{
		{a.DeviceID, a, b},
		{b.DeviceID, b, a},
	} {
		if isFriendOf(state, pair.deviceID, pair.other.PetNo) {
			continue
		}
		state.Friends[pair.deviceID] = append(state.Friends[pair.deviceID], model.FriendEntry{
			PetNo:   pair.other.PetNo,
			PetName: pair.other.PetName,
			AddedAt: now,
		})
	}
}

// findPendingRequest 查待处理的好友申请，返回 map 键（发起设备）与申请本体。
// toPetNo 必匹配；fromDevice / fromPetNo 传空或 0 时不作限定。
func findPendingRequest(state model.SocialState, toPetNo int64, fromDevice string, fromPetNo int64) (string, *model.FriendRequest, bool) {
	for dev, req := range state.Requests {
		if req == nil || req.ToPetNo != toPetNo {
			continue
		}
		if fromDevice != "" && req.FromDevice != fromDevice {
			continue
		}
		if fromPetNo != 0 && req.FromPetNo != fromPetNo {
			continue
		}
		return dev, req, true
	}
	return "", nil, false
}

// clearRequestsBetween 清掉两台设备之间双向的待处理申请（删好友时一并失效）
func clearRequestsBetween(state model.SocialState, deviceA, deviceB string) {
	for dev, req := range state.Requests {
		if req == nil {
			continue
		}
		if (req.FromDevice == deviceA && req.ToPetNo == ownerPetNo(state.Registry[deviceB])) ||
			(req.FromDevice == deviceB && req.ToPetNo == ownerPetNo(state.Registry[deviceA])) {
			delete(state.Requests, dev)
		}
	}
}

// trimPendingRequests 待处理申请全局限流：超出上限丢弃最旧的（按发起设备写入顺序）
func trimPendingRequests(state model.SocialState) {
	for len(state.Requests) > maxPendingReqs {
		var oldestKey string
		var oldest time.Time
		for dev, req := range state.Requests {
			if req == nil {
				delete(state.Requests, dev)
				break
			}
			if oldestKey == "" || req.CreatedAt.Before(oldest) {
				oldestKey, oldest = dev, req.CreatedAt
			}
		}
		if oldestKey == "" {
			return
		}
		delete(state.Requests, oldestKey)
	}
}

// appendHistory 追加一条对话留痕并保持有界（超出上限丢弃最旧的）
func appendHistory(history []model.PetConversationRecord, rec model.PetConversationRecord) []model.PetConversationRecord {
	history = append(history, rec)
	if len(history) > maxHistoryRecords { // 超出上限丢弃最旧，保证有界
		history = history[len(history)-maxHistoryRecords:]
	}
	return history
}

// markHistoryStatus 按申请 ID 回写留痕状态与处理时间
func markHistoryStatus(state model.SocialState, requestID, status string, at time.Time) {
	for i := range state.History {
		if state.History[i].Kind != model.ConversationKindRequest {
			continue
		}
		if !historyHasID(state.History[i], requestID) {
			continue
		}
		state.History[i].Status = status
		state.History[i].HandledAt = at
		return
	}
}

// markHistoryDelivered 记下本批消息的下发时间（接收端尚未确认已读时的中间态）
func markHistoryDelivered(state model.SocialState, deviceID string, msgs []model.PetMessage, at time.Time) {
	if len(msgs) == 0 {
		return
	}
	ids := make(map[string]struct{}, len(msgs))
	for _, m := range msgs {
		ids[m.ID] = struct{}{}
	}
	for i := range state.History {
		if state.History[i].ToDeviceID != deviceID {
			continue
		}
		if state.History[i].DeliveredAt.IsZero() && historyHasAnyID(state.History[i], ids) {
			state.History[i].DeliveredAt = at
		}
	}
}

// markHistoryRead 按消息 ID 给留痕盖已读时间，返回命中条数
func markHistoryRead(state model.SocialState, deviceID string, ids map[string]struct{}, at time.Time) int {
	hit := 0
	for i := range state.History {
		if state.History[i].Kind != model.ConversationKindMessage || !state.History[i].ReadAt.IsZero() {
			continue
		}
		if deviceID != "" && state.History[i].ToDeviceID != deviceID {
			continue
		}
		if !historyHasAnyID(state.History[i], ids) {
			continue
		}
		state.History[i].ReadAt = at
		hit++
	}
	return hit
}

// historyHasID 留痕是否关联了指定 ID
func historyHasID(rec model.PetConversationRecord, id string) bool {
	for _, v := range rec.IDs {
		if v == id {
			return true
		}
	}
	return false
}

// historyHasAnyID 留痕是否关联了给定集合中的任一 ID
func historyHasAnyID(rec model.PetConversationRecord, ids map[string]struct{}) bool {
	for _, v := range rec.IDs {
		if _, ok := ids[v]; ok {
			return true
		}
	}
	return false
}

// newSocialID 生成 32 位 hex 的唯一 ID（消息与好友申请共用，风格与图片对象 ID 一致）
func newSocialID() string {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf[:])
}
