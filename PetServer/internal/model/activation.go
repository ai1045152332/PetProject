package model

import "time"

// ActivationCode 激活码：一码最多绑定 maxDevices 台设备
type ActivationCode struct {
	Code       string    `json:"code"`       // 激活码，格式 XXXX-XXXX-XXXX
	MaxDevices int       `json:"maxDevices"` // 最多绑定设备数
	Devices    []string  `json:"devices"`    // 已绑定设备 ID 列表
	CreatedAt  time.Time `json:"createdAt"`  // 生成时间
	Note       string    `json:"note"`       // 备注（如购买渠道/买家）
}

// CanActivate 判断设备能否用该码激活：
// 已绑定过该设备的直接通过；未绑定的在设备数未满时可绑定
func (c *ActivationCode) CanActivate(deviceID string) bool {
	for _, d := range c.Devices {
		if d == deviceID {
			return true
		}
	}
	return len(c.Devices) < c.MaxDevices
}

// Bind 绑定设备（调用前需 CanActivate 为 true）
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
	Reason string `json:"reason"` // ok / invalid_code / device_limit
}
