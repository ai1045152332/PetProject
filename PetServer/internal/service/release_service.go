package service

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"petserver/internal/model"
)

// ReleaseService 版本发布信息读取（安装包与 manifest 放在 dist 目录）
type ReleaseService struct {
	distDir string
}

// NewReleaseService 创建版本服务
func NewReleaseService(distDir string) *ReleaseService {
	return &ReleaseService{distDir: distDir}
}

// Latest 读取最新版本信息；未发布任何版本时返回 nil
func (s *ReleaseService) Latest() (*model.Release, error) {
	data, err := os.ReadFile(filepath.Join(s.distDir, "latest.json"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}

	var release model.Release
	if err := json.Unmarshal(data, &release); err != nil {
		return nil, fmt.Errorf("解析 latest.json 失败: %w", err)
	}
	return &release, nil
}

// OpenPackage 打开指定安装包文件（仅允许 dist 目录内的文件，防目录穿越）
func (s *ReleaseService) OpenPackage(name string) (string, error) {
	base := filepath.Base(name)
	if base != name || base == "." || base == ".." {
		return "", fmt.Errorf("非法文件名")
	}
	path := filepath.Join(s.distDir, base)
	if _, err := os.Stat(path); err != nil {
		return "", err
	}
	return path, nil
}
