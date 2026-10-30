// social_service.go 好友与宠物消息业务
// 职责：给设备分配稳定宠物号、维护好友关系（加好友需对方同意，同意后双向互加）、
// 投递/拉取消息（下发后等接收端看完关卡确认已读，未确认按间隔重投几次）。
// 本文件只写业务规则与分支，数据读写一律走 storage.SocialRepo（当前为 SQLite 实现）。
package service

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// 消息与好友申请相关的边界常量
const (
	maxInboxPerDevice = 50               // 每设备收件箱待确认消息上限（超出丢弃最旧的）
	maxMessageRunes   = 200              // 单条消息文本长度上限（按字符计）
	maxHistoryRecords = 1000             // 对话留痕保留条数（超出丢弃最旧的，供后台查看）
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

// 好友申请留痕的三种状态
const (
	requestStatusPending  = "pending"
	requestStatusAccepted = "accepted"
	requestStatusRejected = "rejected"
)

// SocialService 好友与消息服务
type SocialService struct {
	mu   sync.Mutex // 串行化业务动作：申请/同意、下发/已读都是成对读改写
	repo storage.SocialRepo
}

// NewSocialService 创建好友与消息服务
func NewSocialService(repo storage.SocialRepo) *SocialService {
	return &SocialService{repo: repo}
}

// validDevice 判断 deviceId 是否可用于好友/消息（排除空与本地占位）
func validSocialDevice(deviceID string) bool {
	return deviceID != "" && deviceID != "unknown-device"
}

// EnsureRegistered 确保设备已注册：新设备分配自增宠物号，刷新展示信息与最近在线时间。
// 返回该设备的宠物号；deviceID 无效或存储异常时返回 0（该设备暂不参与好友/消息）。
// 心跳每次上报都会调用，设置面板「刷新」也会调用，故宠物号在未心跳时也能即时拿到。
func (s *SocialService) EnsureRegistered(deviceID, hostname, petName string) int64 {
	if !validSocialDevice(deviceID) {
		return 0
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// 先看一眼是否新设备，只为把「分配宠物号」这条日志留在业务层
	reg, err := s.repo.DeviceByID(deviceID)
	if err != nil {
		log.Printf("[social] 读取状态失败(注册前查): %v", err)
		return 0
	}
	petNo, err := s.repo.Register(deviceID, hostname, petName, time.Now())
	if err != nil {
		log.Printf("[social] 读取状态失败(注册): %v", err)
		return 0
	}
	if reg == nil {
		log.Printf("[social] 新设备注册，分配宠物号 %d", petNo)
	}
	return petNo
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

	now := time.Now()
	owner, err := s.repo.DeviceByID(ownerDeviceID)
	if err != nil {
		return nil, "", err
	}
	if owner == nil {
		return nil, "", ErrSocialInvalidDevice
	}
	if owner.PetNo == petNo {
		return nil, "", ErrSocialAddSelf
	}
	target, err := s.repo.DeviceByPetNo(petNo)
	if err != nil {
		return nil, "", err
	}
	if target == nil {
		return nil, "", ErrSocialPetNotFound
	}

	// 双向已是好友：幂等成功，不重复发申请
	mine, err := s.repo.IsFriend(ownerDeviceID, petNo)
	if err != nil {
		return nil, "", err
	}
	theirs, err := s.repo.IsFriend(target.DeviceID, owner.PetNo)
	if err != nil {
		return nil, "", err
	}
	if mine && theirs {
		friends, err := s.repo.Friends(ownerDeviceID)
		return friends, FriendRequestMutual, err
	}

	// 对向申请待处理（对方也加过我方）：本次视为互相同意，直接双向互加
	opposed, err := s.repo.FindRequest(owner.PetNo, target.DeviceID, 0)
	if err != nil {
		return nil, "", err
	}
	if opposed != nil {
		if err := s.repo.DropRequest(opposed.ID); err != nil {
			return nil, "", err
		}
		if err := s.repo.MarkRequestHandled(opposed.ID, requestStatusAccepted, now); err != nil {
			return nil, "", err
		}
		if err := s.repo.MakeMutualFriends(owner, target, now); err != nil {
			return nil, "", err
		}
		log.Printf("[social] 双向申请自动成为好友：%d(%s) ↔ %d(%s)", owner.PetNo, owner.PetName, target.PetNo, target.PetName)
		friends, err := s.repo.Friends(ownerDeviceID)
		return friends, FriendRequestMutual, err
	}

	// 已有相同方向的待处理申请：幂等，不重复发
	pending, err := s.repo.FindRequest(target.PetNo, ownerDeviceID, 0)
	if err != nil {
		return nil, "", err
	}
	if pending == nil {
		req := &model.FriendRequest{
			ID:         newSocialID(),
			FromDevice: ownerDeviceID,
			FromPetNo:  owner.PetNo,
			FromName:   owner.PetName,
			ToPetNo:    target.PetNo,
			CreatedAt:  now,
		}
		if err := s.repo.PutRequest(req); err != nil {
			return nil, "", err
		}
		if err := s.repo.AppendHistory(model.PetConversationRecord{
			Kind:       model.ConversationKindRequest,
			FromPetNo:  owner.PetNo,
			FromName:   owner.PetName,
			FromHost:   owner.Hostname,
			ToPetNo:    target.PetNo,
			ToName:     target.PetName,
			ToHost:     target.Hostname,
			ToDeviceID: target.DeviceID,
			IDs:        []string{req.ID},
			Status:     requestStatusPending,
			Text:       fmt.Sprintf("%s(#%d) 申请加你为好友", owner.PetName, owner.PetNo),
			SentAt:     req.CreatedAt,
		}, maxHistoryRecords); err != nil {
			return nil, "", err
		}
		if err := s.repo.TrimRequests(maxPendingReqs); err != nil {
			return nil, "", err
		}
		log.Printf("[social] 设备 %s 向 %d(%s) 发起好友申请（待对方同意）", maskDeviceID(ownerDeviceID), target.PetNo, target.PetName)
	}

	friends, err := s.repo.Friends(ownerDeviceID)
	return friends, FriendRequestPending, err
}

// PendingRequests 拉取发给某设备的全部待处理好友申请（只读：不清除，直到对方同意/拒绝）。
// 客户端据此弹卡与在设置面板列待办，重复下发靠本地已展示 ID 去重。结果按发起时间旧 → 新。
func (s *SocialService) PendingRequests(deviceID string) []model.FriendRequest {
	if !validSocialDevice(deviceID) {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	self, err := s.repo.DeviceByID(deviceID)
	if err != nil || self == nil {
		return nil
	}
	reqs, err := s.repo.RequestsTo(self.PetNo)
	if err != nil {
		log.Printf("[social] 读取待处理申请失败: %v", err)
		return nil
	}
	if len(reqs) == 0 {
		return nil
	}
	return reqs
}

// AcceptFriendRequest 同意发给本设备的好友申请：同意后双方互为好友，返回本设备的好友列表。
func (s *SocialService) AcceptFriendRequest(handlerDeviceID string, fromPetNo int64) ([]model.FriendEntry, error) {
	return s.handleFriendRequest(handlerDeviceID, fromPetNo, requestStatusAccepted)
}

// RejectFriendRequest 拒绝对方的好友申请（不建立好友关系）。
func (s *SocialService) RejectFriendRequest(handlerDeviceID string, fromPetNo int64) ([]model.FriendEntry, error) {
	return s.handleFriendRequest(handlerDeviceID, fromPetNo, requestStatusRejected)
}

// handleFriendRequest 同意/拒绝的共用处理：定位待处理申请，仅同意时双向互加
func (s *SocialService) handleFriendRequest(handlerDeviceID string, fromPetNo int64, status string) ([]model.FriendEntry, error) {
	if !validSocialDevice(handlerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	handler, err := s.repo.DeviceByID(handlerDeviceID)
	if err != nil {
		return nil, err
	}
	if handler == nil {
		return nil, ErrSocialInvalidDevice
	}
	req, err := s.repo.FindRequest(handler.PetNo, "", fromPetNo)
	if err != nil {
		return nil, err
	}
	if req == nil {
		return nil, ErrSocialNoRequest
	}

	if err := s.repo.MarkRequestHandled(req.ID, status, now); err != nil {
		return nil, err
	}
	if err := s.repo.DropRequest(req.ID); err != nil { // 处理完的申请不再占位（结果已落留痕）
		return nil, err
	}

	if status == requestStatusAccepted {
		requester, err := s.repo.DeviceByID(req.FromDevice)
		if err != nil {
			return nil, err
		}
		if requester == nil {
			return nil, ErrSocialPetNotFound
		}
		if err := s.repo.MakeMutualFriends(handler, requester, now); err != nil {
			return nil, err
		}
	}

	friends, err := s.repo.Friends(handlerDeviceID)
	if err != nil {
		return nil, err
	}
	log.Printf("[social] 设备 %s %s 了 %d 的好友申请", maskDeviceID(handlerDeviceID), status, fromPetNo)
	return friends, nil
}

// ListFriends 返回某设备的好友列表
func (s *SocialService) ListFriends(ownerDeviceID string) ([]model.FriendEntry, error) {
	if !validSocialDevice(ownerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	return s.repo.Friends(ownerDeviceID)
}

// RemoveFriend 删除好友：同意后是双向关系，删除也双向解除，并清掉双方间的待处理申请。
// 返回删除后的好友列表。
func (s *SocialService) RemoveFriend(ownerDeviceID string, petNo int64) ([]model.FriendEntry, error) {
	if !validSocialDevice(ownerDeviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	owner, err := s.repo.DeviceByID(ownerDeviceID)
	if err != nil {
		return nil, err
	}
	target, err := s.repo.DeviceByPetNo(petNo)
	if err != nil {
		return nil, err
	}

	// 对方设备已不存在时只解自己这一侧，避免删不掉历史残留的好友条目
	otherDeviceID, selfPetNo := "", int64(0)
	if target != nil {
		otherDeviceID, selfPetNo = target.DeviceID, petNoOf(owner)
	}
	if err := s.repo.DropFriendship(ownerDeviceID, petNo, otherDeviceID, selfPetNo); err != nil {
		return nil, err
	}
	if target != nil {
		if err := s.repo.DropRequestsBetween(ownerDeviceID, petNoOf(owner), target.DeviceID, target.PetNo); err != nil {
			return nil, err
		}
		log.Printf("[social] 设备 %s 删除好友 %d（双向解除）", maskDeviceID(ownerDeviceID), petNo)
	}

	return s.repo.Friends(ownerDeviceID)
}

// SendMessage 由 fromDeviceID 给宠物号 toPetNo 发一条消息，落到对方收件箱等待其心跳拉取展示。
// 要求双方已互加好友（需对方同意过）；接收方离线时消息暂存云端。
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

	sender, err := s.repo.DeviceByID(fromDeviceID)
	if err != nil {
		return err
	}
	if sender == nil {
		return ErrSocialInvalidDevice
	}
	target, err := s.repo.DeviceByPetNo(toPetNo)
	if err != nil {
		return err
	}
	if target == nil {
		return ErrSocialPetNotFound
	}
	// 好友校验：双方都在彼此好友列表里才允许发（同意后的互加状态）
	mine, err := s.repo.IsFriend(fromDeviceID, toPetNo)
	if err != nil {
		return err
	}
	theirs, err := s.repo.IsFriend(target.DeviceID, sender.PetNo)
	if err != nil {
		return err
	}
	if !mine || !theirs {
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
	if err := s.repo.PushMessage(target.DeviceID, msg, maxInboxPerDevice); err != nil {
		return err
	}

	// 对话留痕：这里持久保留一份供管理后台查看好友间对话，
	// 并记下消息 ID 以便接收端关卡时回填下发/已读时间
	if err := s.repo.AppendHistory(model.PetConversationRecord{
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
	}, maxHistoryRecords); err != nil {
		return err
	}

	log.Printf("[social] %d → %d 消息已投递（对方下次心跳拉取）", sender.PetNo, target.PetNo)
	return nil
}

// PeekPendingMessages 只读预览某设备待展示消息：收件箱里从未下发过的，加上到点该重投的。
// 不改动状态，供心跳先下发、确认设备有效后再登记下发时间。
func (s *SocialService) PeekPendingMessages(deviceID string) []model.PetMessage {
	if !validSocialDevice(deviceID) {
		return nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	msgs, err := s.repo.PendingMessages(deviceID, time.Now(), storage.PendingQuery{
		RedeliverAfter:  redeliverAfter,
		MaxDeliverTimes: maxDeliverTimes,
		TTL:             deliveredTTL,
	})
	if err != nil {
		log.Printf("[social] 读取待下发消息失败: %v", err)
		return nil
	}
	return msgs
}

// DeliverMessages 登记这批消息为「已下发、待确认已读」：收件箱保留原样，
// 只有接收端看完关卡调 MarkMessagesRead 才真正清除，避免没看完就退出把消息丢在云端。
func (s *SocialService) DeliverMessages(deviceID string, msgs []model.PetMessage) {
	if !validSocialDevice(deviceID) || len(msgs) == 0 {
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	ids := make([]string, 0, len(msgs))
	for _, m := range msgs {
		ids = append(ids, m.ID)
	}
	now := time.Now()
	// 收件箱与下发状态同表同行，行数已被 PushMessage 的每设备上限约束，无需再单独裁剪
	if err := s.repo.MarkDelivered(deviceID, ids, now); err != nil {
		log.Printf("[social] 保存状态失败(登记下发): %v", err)
		return
	}
	if err := s.repo.MarkHistoryDelivered(deviceID, ids, now); err != nil {
		log.Printf("[social] 保存状态失败(登记下发留痕): %v", err)
	}
}

// MarkMessagesRead 由接收端（看完消息并关卡时）确认已读：
// 从收件箱与「已下发」名单中清除这些 ID，并把对应对话留痕标上已读时间，
// 让后台能看到对方到底有没有读过。返回实际命中的留痕条数。
func (s *SocialService) MarkMessagesRead(deviceID string, ids []string) (int, error) {
	if !validSocialDevice(deviceID) {
		return 0, ErrSocialInvalidDevice
	}
	seen := make(map[string]struct{}, len(ids))
	wanted := make([]string, 0, len(ids))
	for _, id := range ids {
		if id == "" {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		wanted = append(wanted, id)
	}
	if len(wanted) == 0 {
		return 0, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.repo.DeleteMessages(deviceID, wanted); err != nil {
		return 0, err
	}
	hit, err := s.repo.MarkHistoryRead(deviceID, wanted, time.Now())
	if err != nil {
		return 0, err
	}
	log.Printf("[social] 设备 %s 确认已读 %d 条消息", maskDeviceID(deviceID), hit)
	return hit, nil
}

// Conversations 返回全部对话留痕（旧 → 新），供管理后台展示；无记录时返回空切片。
func (s *SocialService) Conversations() []model.PetConversationRecord {
	s.mu.Lock()
	defer s.mu.Unlock()

	out, err := s.repo.History(maxHistoryRecords)
	if err != nil {
		log.Printf("[social] 读取状态失败(对话记录): %v", err)
		return []model.PetConversationRecord{}
	}
	return out
}

// maxChatHistoryRows 好友聊天窗单次回看的历史条数上限（留痕全局有界，这里只取最近一段）
const maxChatHistoryRows = 200

// ConversationBetween 返回本设备与好友宠物号之间的最近聊天记录（旧 → 新，供聊天窗回看）。
// 仅开放消息留痕；要求双方已互加好友，否则按 ErrSocialNotFriend 拒绝（隐私边界：非好友摸不到往来）。
func (s *SocialService) ConversationBetween(deviceID string, friendPetNo int64) ([]model.PetConversationRecord, error) {
	if !validSocialDevice(deviceID) {
		return nil, ErrSocialInvalidDevice
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	self, err := s.repo.DeviceByID(deviceID)
	if err != nil {
		return nil, err
	}
	if self == nil {
		return nil, ErrSocialInvalidDevice
	}
	target, err := s.repo.DeviceByPetNo(friendPetNo)
	if err != nil {
		return nil, err
	}
	if target == nil {
		return nil, ErrSocialPetNotFound
	}
	// 与 SendMessage 同样的双向好友校验：未互相同意过不开放回看
	mine, err := s.repo.IsFriend(deviceID, friendPetNo)
	if err != nil {
		return nil, err
	}
	theirs, err := s.repo.IsFriend(target.DeviceID, self.PetNo)
	if err != nil {
		return nil, err
	}
	if !mine || !theirs {
		return nil, ErrSocialNotFriend
	}

	return s.repo.HistoryBetween(self.PetNo, friendPetNo, maxChatHistoryRows)
}

// ClearConversations 清空全部对话留痕（管理后台维护用）。
func (s *SocialService) ClearConversations() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := s.repo.ClearHistory(); err != nil {
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

	reg, err := s.repo.DeviceByID(deviceID)
	if err != nil || reg == nil {
		return 0
	}
	return reg.PetNo
}

// petNoOf 取注册信息的宠物号；未注册时返回 0（只会匹配到无效好友号）
func petNoOf(reg *model.PetRegistration) int64 {
	if reg == nil {
		return 0
	}
	return reg.PetNo
}

// newSocialID 生成 32 位 hex 的唯一 ID（消息与好友申请共用，风格与图片对象 ID 一致）
func newSocialID() string {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf[:])
}
