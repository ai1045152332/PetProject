package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"petserver/internal/model"
)

// ApiMetricsStore 接口调用计数持久化（重启后累计数不丢）
type ApiMetricsStore struct {
	mu   sync.Mutex
	path string
}

// NewApiMetricsStore 创建接口计数存储
func NewApiMetricsStore(path string) (*ApiMetricsStore, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return &ApiMetricsStore{path: path}, nil
}

// apiMetricsFile 落盘结构：计数起点与统计数据一起存，
// 否则重启后「自 X 起累计」会退化成启动时间，与恢复出来的累计数不一致
type apiMetricsFile struct {
	SinceAt time.Time                  `json:"sinceAt"`
	Stats   map[string]model.ApiMetric `json:"stats"`
}

// Load 读取历史计数；文件不存在返回空表（首次启动）
// 兼容早期仅存统计表的格式（无 sinceAt，起点退化为文件修改时间）
func (s *ApiMetricsStore) Load() (map[string]model.ApiMetric, time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return map[string]model.ApiMetric{}, time.Time{}, nil
	}
	if err != nil {
		return nil, time.Time{}, err
	}

	var file apiMetricsFile
	if err := json.Unmarshal(data, &file); err == nil && file.Stats != nil {
		return file.Stats, file.SinceAt, nil
	}

	// 旧格式：顶层就是 map[接口]计数
	legacy := map[string]model.ApiMetric{}
	if err := json.Unmarshal(data, &legacy); err != nil {
		return nil, time.Time{}, err
	}
	since := time.Time{}
	if st, statErr := os.Stat(s.path); statErr == nil {
		since = st.ModTime()
	}
	return legacy, since, nil
}

// Save 全量写回（临时文件 + rename，避免写一半被读到）
func (s *ApiMetricsStore) Save(stats map[string]model.ApiMetric, since time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	data, err := json.MarshalIndent(apiMetricsFile{SinceAt: since, Stats: stats}, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
