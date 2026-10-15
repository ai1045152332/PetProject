package model

// AccessVerifyRequest 校验码校验请求
type AccessVerifyRequest struct {
	Code     string `json:"code"`     // 用户输入的校验码/激活码
	DeviceID string `json:"deviceId"` // 设备唯一标识（macOS IOPlatformUUID）
}
