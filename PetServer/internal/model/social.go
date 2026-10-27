// social.go 好友与宠物消息相关的数据模型
// 每只宠物（按设备 deviceId）分配一个友好的「宠物号」，供加好友与发消息寻址；
// 消息量级不大，先整体存云端本地 JSON，接收方通过心跳拉取。
package model

import "time"

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

// PetMessage 宠物消息：好友发来、待接收方下次心跳拉取并展示的一条消息
type PetMessage struct {
	ID        string    `json:"id"`
	FromPetNo int64     `json:"fromPetNo"`
	FromName  string    `json:"fromName"`
	Text      string    `json:"text"`
	SentAt    time.Time `json:"sentAt"`
}

// PetConversationRecord 宠物对话记录：发送消息时在服务端留痕，供管理后台查看好友之间的往来对话
// （收件箱消息被心跳取走后即清除，这里独立持久保留）
type PetConversationRecord struct {
	FromPetNo int64     `json:"fromPetNo"`
	FromName  string    `json:"fromName"`
	FromHost  string    `json:"fromHost"` // 发送方主机名，便于后台识别是哪台设备
	ToPetNo   int64     `json:"toPetNo"`
	ToName    string    `json:"toName"`
	ToHost    string    `json:"toHost"`
	Text      string    `json:"text"`
	SentAt    time.Time `json:"sentAt"`
}

// SocialState 好友与消息的整体持久化状态（单 JSON 文件，整体读写）
type SocialState struct {
	Counter  int64                       `json:"counter"`  // 已发放的宠物号水位（用于自增分配）
	Registry map[string]*PetRegistration `json:"registry"` // deviceId → 注册信息
	Friends  map[string][]FriendEntry    `json:"friends"`  // deviceId → 好友列表
	Inbox    map[string][]PetMessage     `json:"inbox"`    // deviceId → 待拉取消息
	History  []PetConversationRecord     `json:"history"`  // 对话留痕（旧 → 新，有界）
}
