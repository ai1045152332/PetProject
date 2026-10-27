// social.go 好友与宠物消息相关的数据模型
// 每只宠物（按设备 deviceId）分配一个友好的「宠物号」，供加好友与发消息寻址；
// 消息量级不大，先整体存云端本地 JSON，接收方通过心跳拉取。
package model

import "time"

// 对话留痕的类型与状态（Kind）：消息走收件箱投递，申请需对方同意才成为好友
const (
	ConversationKindMessage = "message" // 好友留言（默认）
	ConversationKindRequest = "request" // 加好友申请
)

// PetRegistration 宠物注册信息：一台设备对应一个稳定的宠物号
type PetRegistration struct {
	DeviceID    string    `json:"deviceId"`
	PetNo       int64     `json:"petNo"`
	PetName     string    `json:"petName"`
	Hostname    string    `json:"hostname"`
	FirstSeenAt time.Time `json:"firstSeenAt"`
	LastSeenAt  time.Time `json:"lastSeenAt"`
}

// FriendEntry 好友条目：某设备添加的一只宠物（添加时快照其名称）
type FriendEntry struct {
	PetNo   int64     `json:"petNo"`
	PetName string    `json:"petName"`
	AddedAt time.Time `json:"addedAt"`
}

// FriendRequest 加好友申请：由发起方写入，接收方同意后才双向成为好友
type FriendRequest struct {
	ID         string    `json:"id"` // 32 位 hex，留痕状态回查用
	FromDevice string    `json:"fromDevice"`
	FromPetNo  int64     `json:"fromPetNo"`
	FromName   string    `json:"fromName"`
	ToPetNo    int64     `json:"toPetNo"`
	CreatedAt  time.Time `json:"createdAt"`
}

// DeliveredMessage 已下发但未确认已读的消息：收件箱仍保留副本，超过重投间隔且
// 未超龄/未达次数上限时再次下发，避免接收端没看完就退出把消息丢在“取后即清”那一步。
type DeliveredMessage struct {
	Message     PetMessage `json:"message"`
	DeliveredAt time.Time  `json:"deliveredAt"` // 最近一次下发时间
	Times       int        `json:"times"`       // 已下发次数
}

// PetMessage 宠物消息：好友发来、待接收方下次心跳拉取并展示的一条消息
type PetMessage struct {
	ID        string    `json:"id"` // 全局唯一（含接收方设备 ID），已读确认按它回查留痕
	FromPetNo int64     `json:"fromPetNo"`
	FromName  string    `json:"fromName"`
	Text      string    `json:"text"`
	SentAt    time.Time `json:"sentAt"`
}

// PetConversationRecord 宠物对话记录：发送消息时在服务端留痕，供管理后台查看好友之间的往来对话
// （收件箱消息被心跳取走后即清除，这里独立持久保留）
type PetConversationRecord struct {
	Kind      string    `json:"kind,omitempty"` // message（默认）/ request
	FromPetNo int64     `json:"fromPetNo"`
	FromName  string    `json:"fromName"`
	FromHost  string    `json:"fromHost"` // 发送方主机名，便于后台识别是哪台设备
	ToPetNo   int64     `json:"toPetNo"`
	ToName    string    `json:"toName"`
	ToHost    string    `json:"toHost"`
	Text      string    `json:"text"`
	SentAt    time.Time `json:"sentAt"`

	ToDeviceID string   `json:"toDeviceId,omitempty"` // 接收方设备，用于定位归属记录
	IDs        []string `json:"ids,omitempty"`        // 关联的消息 ID / 申请 ID

	DeliveredAt time.Time `json:"deliveredAt,omitempty"` // 下发给接收端的时间
	ReadAt      time.Time `json:"readAt,omitempty"`      // 接收端确认已读时间
	HandledAt   time.Time `json:"handledAt,omitempty"`   // 好友申请被同意/拒绝的时间
	Status      string    `json:"status,omitempty"`      // 申请状态：pending / accepted / rejected
}

// SocialState 好友与消息的整体持久化状态（单 JSON 文件，整体读写）
type SocialState struct {
	Counter   int64                                  `json:"counter"`   // 已发放的宠物号水位（用于自增分配）
	Registry  map[string]*PetRegistration            `json:"registry"`  // deviceId → 注册信息
	Friends   map[string][]FriendEntry               `json:"friends"`   // deviceId → 好友列表
	Inbox     map[string][]PetMessage                `json:"inbox"`     // deviceId → 待拉取消息
	Delivered map[string]map[string]DeliveredMessage `json:"delivered"` // deviceId → 消息 ID → 已下发待确认已读
	Requests  map[string]*FriendRequest              `json:"requests"`  // 发起方 deviceId → 待处理的加好友申请
	History   []PetConversationRecord                `json:"history"`   // 对话留痕（旧 → 新，有界）
}
