// push.go 服务端主动推送：更新 / 播文字 / 播视频
// 与好友消息不同，这类指令由运营在后台发起，随心跳一次性下发到指定设备（或全量广播），
// 客户端执行后不再重投（DeliveredTo 去重）。
package model

import "time"

// 推送指令类型
const (
	PushKindUpdate = "update" // 触发客户端检查更新
	PushKindText   = "text"   // 弹一张文字卡片
	PushKindVideo  = "video"  // 弹视频窗口播放 URL
)

// PushCommand 一条待下发的推送指令
type PushCommand struct {
	ID         string    `json:"id"`
	DeviceID   string    `json:"deviceId,omitempty"` // 空 = 广播给所有带 deviceId 的心跳
	Kind       string    `json:"kind"`
	Title      string    `json:"title,omitempty"`
	Text       string    `json:"text,omitempty"`
	URL        string    `json:"url,omitempty"`
	DurationMs int64     `json:"durationMs,omitempty"` // 文字卡自动关闭时长（0 = 不自动关）
	CreatedAt  time.Time `json:"createdAt"`
	ExpiresAt  time.Time `json:"expiresAt,omitempty"`
	// 已下发过的设备（广播指令按设备去重；单发指令下发一次即记一笔）
	DeliveredTo []string `json:"deliveredTo,omitempty"`
}

// Expired 指令是否已过期（过期不再下发）
func (c *PushCommand) Expired(now time.Time) bool {
	return !c.ExpiresAt.IsZero() && now.After(c.ExpiresAt)
}

// Delivered 该指令是否已下发给指定设备
func (c *PushCommand) Delivered(deviceID string) bool {
	for _, id := range c.DeliveredTo {
		if id == deviceID {
			return true
		}
	}
	return false
}
