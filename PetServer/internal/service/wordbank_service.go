// wordbank_service.go
// 背单词词库分发：词库以 JSON 文件放在锚定目录内，客户端拉取后本地缓存；
// 文件可通过后台文件管理页维护，改词库无需重新发版。
package service

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// wordBankNameRe 词库名白名单：小写字母/数字/连字符，从源头杜绝路径穿越
var wordBankNameRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// WordBankEntry 词库条目信息（Size 供客户端做增量签名对比）
type WordBankEntry struct {
	Name string `json:"name"` // 词库名（文件名去 .json），如 cet4
	Size int64  `json:"size"` // 文件字节数
}

// WordBankService 词库读取服务
type WordBankService struct {
	root string // 锚定的绝对目录，只允许读取其下的 *.json
}

// NewWordBankService 创建词库服务，root 为词库目录（不存在时自动创建）
func NewWordBankService(root string) (*WordBankService, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("解析词库目录失败: %w", err)
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, fmt.Errorf("词库目录不可用: %w", err)
	}
	return &WordBankService{root: abs}, nil
}

// Root 返回锚定的绝对词库目录
func (s *WordBankService) Root() string { return s.root }

// validName 校验词库名合法性
func (s *WordBankService) validName(name string) bool {
	return wordBankNameRe.MatchString(name)
}

// List 列出全部词库（*.json），按名称排序；命名不合法的文件静默跳过
func (s *WordBankService) List() ([]WordBankEntry, error) {
	items, err := os.ReadDir(s.root)
	if err != nil {
		return nil, fmt.Errorf("读取词库目录失败: %w", err)
	}
	entries := make([]WordBankEntry, 0, len(items))
	for _, item := range items {
		if item.IsDir() || !strings.HasSuffix(item.Name(), ".json") {
			continue
		}
		name := strings.TrimSuffix(item.Name(), ".json")
		if !s.validName(name) {
			continue
		}
		fi, err := item.Info()
		if err != nil {
			continue
		}
		entries = append(entries, WordBankEntry{Name: name, Size: fi.Size()})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })
	return entries, nil
}

// Open 按词库名读取 JSON 原文（越界/非法名/不存在直接拒绝）
func (s *WordBankService) Open(name string) ([]byte, error) {
	if !s.validName(name) {
		return nil, fmt.Errorf("非法词库名: %s", name)
	}
	full := filepath.Join(s.root, name+".json")
	// 双保险：拼接结果必须仍在词库目录内
	if !strings.HasPrefix(full, s.root+string(filepath.Separator)) {
		return nil, fmt.Errorf("路径越界: %s", name)
	}
	data, err := os.ReadFile(full)
	if os.IsNotExist(err) {
		return nil, fmt.Errorf("词库不存在: %s", name)
	}
	if err != nil {
		return nil, fmt.Errorf("读取词库失败: %w", err)
	}
	return data, nil
}
