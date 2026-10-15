package model

import "time"

// ActivationCode 激活码：一码最多绑定 maxDevices 台设备
type ActivationCode struct {
	Code       string     `json:"code"`       // 激活码，格式 XXXX-XXXX-XXXX
	MaxDevices int        `json:"maxDevices"` // 最多绑定设备数
	Devices    []string   `json:"devices"`    // 已绑定设备 ID 列表
	CreatedAt  time.Time  `json:"createdAt"`  // 生成时间
	ExpiresAt  *time.Time `json:"expiresAt"`  // 过期时间（nil = 永久有效）
	Note       string     `json:"note"`       // 备注（如购买渠道/买家）
}

// Expired 是否已过期（过期时间往前判断，nil 表示永久有效）
func (c *ActivationCode) Expired(now time.Time) bool {
	return c.ExpiresAt != nil && now.After(*c.ExpiresAt)
}

// ActivationStatus 判断该码对某设备的激活状态：
// ok / expired / device_limit
func (c *ActivationCode) ActivationStatus(deviceID string, now time.Time) string {
	if c.Expired(now) {
		return "expired"
	}
	for _, d := range c.Devices {
		if d == deviceID {
			return "ok"
		}
	}
	if len(c.Devices) >= c.MaxDevices {
		return "device_limit"
	}
	return "ok"
}

// Bind 绑定设备（调用前需 ActivationStatus 为 ok）
func (c *ActivationCode) Bind(deviceID string) {
	for _, d := range c.Devices {
		if d == deviceID {
			return
		}
	}
	c.Devices = append(c.Devices, deviceID)
}

// AccessVerifyResult 校验结果
type AccessVerifyResult struct {
	Valid  bool   `json:"valid"`  // 校验码是否正确
	Reason string `json:"reason"` // ok / invalid_code / device_limit / expired
}
