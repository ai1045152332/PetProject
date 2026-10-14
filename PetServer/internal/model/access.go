package model

// AccessVerifyRequest 校验码校验请求
type AccessVerifyRequest struct {
	Code string `json:"code"` // 用户输入的校验码
}

// AccessVerifyResult 校验结果
type AccessVerifyResult struct {
	Valid bool `json:"valid"` // 校验码是否正确
}
