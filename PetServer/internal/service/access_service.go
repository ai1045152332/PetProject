package service

import (
	"crypto/rand"
	"fmt"
	"log"
	"strings"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// codeAlphabet 激活码字符集（去掉易混淆的 0/O、1/I/L）
const codeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

// AccessService 激活码相关业务：生成、校验、设备绑定
type AccessService struct {
	store *storage.ActivationStore
}

// NewAccessService 创建激活码服务实例
func NewAccessService(store *storage.ActivationStore) *AccessService {
	return &AccessService{store: store}
}

// Verify 校验激活码并绑定设备，返回是否通过及原因（ok / invalid_code / device_limit）
func (s *AccessService) Verify(code, deviceID string) (bool, string) {
	normalized := strings.ToUpper(strings.TrimSpace(code))

	codes, err := s.store.Load()
	if err != nil {
		log.Printf("[access] 读取激活码库失败: %v", err)
		return false, "invalid_code"
	}

	for i := range codes {
		if codes[i].Code != normalized {
			continue
		}
		if !codes[i].CanActivate(deviceID) {
			log.Printf("[access] 激活码 %s 设备数已达上限(%d)，设备 %s 拒绝", normalized, codes[i].MaxDevices, maskDeviceID(deviceID))
			return false, "device_limit"
		}
		codes[i].Bind(deviceID)
		if err := s.store.Save(codes); err != nil {
			log.Printf("[access] 保存设备绑定失败: %v", err)
		}
		log.Printf("[access] 激活码 %s 激活成功，设备 %s（%d/%d）", normalized, maskDeviceID(deviceID), len(codes[i].Devices), codes[i].MaxDevices)
		return true, "ok"
	}

	log.Printf("[access] 无效激活码: %s", normalized)
	return false, "invalid_code"
}

// Generate 批量生成激活码并持久化，返回生成的码
func (s *AccessService) Generate(count, maxDevices int, note string) ([]string, error) {
	codes, err := s.store.Load()
	if err != nil {
		return nil, err
	}

	existing := make(map[string]bool, len(codes))
	for _, c := range codes {
		existing[c.Code] = true
	}

	generated := make([]string, 0, count)
	for len(generated) < count {
		code, err := randomCode()
		if err != nil {
			return nil, err
		}
		if existing[code] {
			continue
		}
		existing[code] = true
		codes = append(codes, model.ActivationCode{
			Code:       code,
			MaxDevices: maxDevices,
			Devices:    []string{},
			CreatedAt:  time.Now(),
			Note:       note,
		})
		generated = append(generated, code)
	}

	if err := s.store.Save(codes); err != nil {
		return nil, err
	}
	log.Printf("[access] 生成 %d 个激活码（每码 %d 设备，备注: %s）", count, maxDevices, note)
	return generated, nil
}

// List 返回全部激活码（管理接口用）
func (s *AccessService) List() ([]model.ActivationCode, error) {
	return s.store.Load()
}

// randomCode 生成 XXXX-XXXX-XXXX 格式激活码
func randomCode() (string, error) {
	buf := make([]byte, 12)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("生成随机码失败: %w", err)
	}
	var sb strings.Builder
	for i, b := range buf {
		if i > 0 && i%4 == 0 {
			sb.WriteByte('-')
		}
		sb.WriteByte(codeAlphabet[int(b)%len(codeAlphabet)])
	}
	return sb.String(), nil
}

// maskDeviceID 日志中隐藏设备 ID 中间部分
func maskDeviceID(id string) string {
	if len(id) <= 8 {
		return id
	}
	return id[:4] + "****" + id[len(id)-4:]
}
