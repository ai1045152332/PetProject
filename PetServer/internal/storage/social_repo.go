// social_repo.go 好友与宠物消息的持久化仓库接口
// 粒度对齐业务动作（而不是「整读整写一份状态」）：每次只碰涉及的行，
// 让好友申请、消息下发与已读确认这些会持续增长的关系型数据可以直接用 SQL 查询与排障。
// 目前唯一实现是 SQLite（SocialSQLite）；旧版单 JSON 存储（SocialStore）只作为迁移来源保留。
package storage

import (
	"time"

	"petserver/internal/model"
)

// PendingQuery 心跳下发消息的筛选策略（阈值由业务层决定，仓库只按参数过滤）
type PendingQuery struct {
	RedeliverAfter  time.Duration // 已下发但未确认已读时，隔多久允许再投一次
	MaxDeliverTimes int           // 单条消息最多下发次数（避免无限弹卡）
	TTL             time.Duration // 消息年龄超过这个值不再打扰（留痕仍保留）
}

// SocialRepo 好友与消息存储仓库
type SocialRepo interface {
	// ── 设备注册 ──
	// Register 确保设备已注册：新设备按水位自增分配宠物号，老设备刷新展示信息。
	Register(deviceID, hostname, petName string, now time.Time) (int64, error)
	DeviceByID(deviceID string) (*model.PetRegistration, error)
	DeviceByPetNo(petNo int64) (*model.PetRegistration, error)

	// ── 好友关系（同意后双向互加）──
	Friends(deviceID string) ([]model.FriendEntry, error)
	IsFriend(deviceID string, petNo int64) (bool, error)
	// MakeMutualFriends 双向各补一条好友（已存在的方向不重复写）
	MakeMutualFriends(a, b *model.PetRegistration, now time.Time) error
	// DropFriendship 双向解除：从 ownerDeviceID 删 petNo，并从 otherDeviceID 删 ownerPetNo
	DropFriendship(ownerDeviceID string, otherPetNo int64, otherDeviceID string, ownerPetNo int64) error

	// ── 好友申请 ──
	PutRequest(req *model.FriendRequest) error
	// FindRequest 定位一条待处理申请，返回其主键（发起设备）。找不到时 req 为 nil、err 为 nil。
	// fromDevice / fromPetNo 传空或 0 表示不作限定。
	FindRequest(toPetNo int64, fromDevice string, fromPetNo int64) (string, *model.FriendRequest, error)
	RequestsTo(toPetNo int64) ([]model.FriendRequest, error)
	DropRequest(fromDevice string) error
	// DropRequestsBetween 清掉两台设备之间双向的待处理申请（删好友时一并失效）
	DropRequestsBetween(devA string, petNoA int64, devB string, petNoB int64) error
	// TrimRequests 待处理申请全局限流：只保留最新 keep 条
	TrimRequests(keep int) error

	// ── 消息 ──
	// PushMessage 投递一条消息到接收方收件箱，并按 keepLast 丢弃最旧的超额消息
	PushMessage(toDeviceID string, msg model.PetMessage, keepLast int) error
	// PendingMessages 本次应下发的消息：从未下发过的 + 过了重投间隔仍未确认的（按发送时间旧 → 新）
	PendingMessages(deviceID string, now time.Time, q PendingQuery) ([]model.PetMessage, error)
	// MarkDelivered 登记这批消息刚下发过（下发次数 +1、刷新下发时间）
	MarkDelivered(deviceID string, ids []string, at time.Time) error
	// DeleteMessages 接收端确认已读后，从收件箱与下发名单中一并删除
	DeleteMessages(deviceID string, ids []string) error

	// ── 对话留痕（供管理后台查看）──
	// AppendHistory 追加一条留痕，并按 keepLast 丢弃最旧的超额记录
	AppendHistory(rec model.PetConversationRecord, keepLast int) error
	// History 返回留痕（旧 → 新）；limit <= 0 表示不限条数
	History(limit int) ([]model.PetConversationRecord, error)
	// MarkRequestHandled 按申请 ID 回写处理状态与处理时间
	MarkRequestHandled(requestID, status string, at time.Time) error
	// MarkHistoryDelivered 记下本批消息的首次下发时间（尚未确认已读时的中间态）
	MarkHistoryDelivered(deviceID string, ids []string, at time.Time) error
	// MarkHistoryRead 按消息 ID 给留痕盖已读时间，返回命中条数
	MarkHistoryRead(deviceID string, ids []string, at time.Time) (int, error)
	ClearHistory() error

	Close() error
}
