package service

import (
	"fmt"
	"io"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// 预览文件时读取的最大字节数，超出部分截断返回
const filePreviewLimit = 200 * 1024

// FileEntry 文件/目录条目信息
type FileEntry struct {
	Name      string `json:"name"`
	IsDir     bool   `json:"isDir"`
	Size      int64  `json:"size"`
	ModTime   string `json:"modTime"`
	Sensitive bool   `json:"sensitive"` // 命中敏感黑名单，前端禁用预览
}

// isSensitiveFile 判断文件名是否属于敏感文件（禁止预览）。
// 根目录提到服务目录后，petserver.env（后台密码/天气 Key）、RSA 私钥、
// 会话令牌 sessions.json 都会被列出，必须在预览环节挡住，防止秘密泄露。
func isSensitiveFile(name string) bool {
	lower := strings.ToLower(name)
	if lower == "sessions.json" {
		return true
	}
	for _, ext := range []string{".env", ".pem", ".key"} {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	return false
}

// FilePreview 文件预览内容
type FilePreview struct {
	Path      string `json:"path"`
	Content   string `json:"content"`
	Size      int64  `json:"size"`
	Truncated bool   `json:"truncated"` // 超过预览上限时为 true
}

// FileService 服务器文件管理：在锚定根目录内查看/删除文件，
// 所有相对路径都会先做净化并校验不越界，防止路径穿越（../）。
type FileService struct {
	root string // 锚定的绝对根目录，仅允许操作其下的文件
}

// NewFileService 创建文件管理服务，root 为允许操作的根目录
func NewFileService(root string) (*FileService, error) {
	abs, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("解析根目录失败: %w", err)
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, fmt.Errorf("根目录不可用: %w", err)
	}
	return &FileService{root: abs}, nil
}

// Root 返回锚定的绝对根目录
func (s *FileService) Root() string { return s.root }

// resolve 把请求里的相对路径净化并映射到根目录内，越界直接拒绝
func (s *FileService) resolve(rel string) (string, error) {
	// 统一分隔符并去掉首尾斜杠："" 或 "/" 表示根目录本身
	clean := path.Clean("/" + strings.ReplaceAll(rel, "\\", "/"))
	rel = strings.TrimPrefix(clean, "/")

	full := filepath.Join(s.root, filepath.FromSlash(rel))
	// 双保险：拼接结果必须仍在根目录内（root 自身或 root/ 前缀）
	if full != s.root && !strings.HasPrefix(full, s.root+string(filepath.Separator)) {
		return "", fmt.Errorf("路径越界: %s", rel)
	}
	return full, nil
}

// List 列出目录内容（rel 为空表示根目录），目录在前、文件在后，各按名称排序
func (s *FileService) List(rel string) ([]FileEntry, error) {
	full, err := s.resolve(rel)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(full)
	if err != nil {
		return nil, fmt.Errorf("路径不存在: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("不是目录: %s", rel)
	}

	items, err := os.ReadDir(full)
	if err != nil {
		return nil, fmt.Errorf("读取目录失败: %w", err)
	}

	entries := make([]FileEntry, 0, len(items))
	for _, item := range items {
		// ReadDir 返回 DirEntry，需要 Stat 拿大小/时间（跳过符号链接目标缺失的错误）
		fi, err := item.Info()
		if err != nil {
			continue
		}
		entries = append(entries, FileEntry{
			Name:      item.Name(),
			IsDir:     item.IsDir(),
			Size:      fi.Size(),
			ModTime:   fi.ModTime().Format("2006-01-02 15:04:05"),
			Sensitive: !item.IsDir() && isSensitiveFile(item.Name()),
		})
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	return entries, nil
}

// Preview 读取文本文件内容用于预览，超过 filePreviewLimit 时截断
func (s *FileService) Preview(rel string) (*FilePreview, error) {
	full, err := s.resolve(rel)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(full)
	if err != nil {
		return nil, fmt.Errorf("文件不存在: %w", err)
	}
	if info.IsDir() {
		return nil, fmt.Errorf("是目录，无法预览: %s", rel)
	}
	// 敏感文件黑名单：即使能列出也绝不返回内容（后台密码/私钥/会话令牌）
	if isSensitiveFile(filepath.Base(full)) {
		return nil, fmt.Errorf("敏感文件，禁止预览: %s", rel)
	}
	// 大文件只读预览上限，避免一次性载入超大内容拖垮服务
	f, err := os.Open(full)
	if err != nil {
		return nil, fmt.Errorf("打开文件失败: %w", err)
	}
	defer f.Close()

	buf := make([]byte, filePreviewLimit)
	n, err := io.ReadFull(f, buf)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return nil, fmt.Errorf("读取文件失败: %w", err)
	}
	data := buf[:n]

	return &FilePreview{
		Path:      rel,
		Content:   string(data),
		Size:      info.Size(),
		Truncated: info.Size() > int64(n),
	}, nil
}

// Delete 删除文件或目录（目录递归删除），根目录本身不允许删除
func (s *FileService) Delete(rel string) error {
	full, err := s.resolve(rel)
	if err != nil {
		return err
	}
	if full == s.root {
		return fmt.Errorf("禁止删除根目录本身")
	}
	// 敏感文件（配置/私钥/会话）禁止删除，避免误删导致服务不可用且不可恢复
	if isSensitiveFile(filepath.Base(full)) {
		return fmt.Errorf("敏感文件，禁止删除: %s", rel)
	}
	info, err := os.Stat(full)
	if err != nil {
		return fmt.Errorf("路径不存在: %w", err)
	}
	if err := os.RemoveAll(full); err != nil {
		return fmt.Errorf("删除失败: %w", err)
	}
	kind := "文件"
	if info.IsDir() {
		kind = "目录"
	}
	log.Printf("[files] 已删除%s: %s", kind, rel)
	return nil
}
