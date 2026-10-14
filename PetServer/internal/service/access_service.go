package service

import "log"

// remoteAccessCode 远程校验码（先写死，后续可改为配置或数据库）
const remoteAccessCode = "123"

// AccessService 校验码相关业务
type AccessService struct{}

// NewAccessService 创建校验码服务实例
func NewAccessService() *AccessService {
	return &AccessService{}
}

// Verify 校验输入码是否与远程校验码一致
func (s *AccessService) Verify(code string) bool {
	valid := code == remoteAccessCode
	log.Printf("[access] 校验码验证: valid=%v", valid)
	return valid
}
