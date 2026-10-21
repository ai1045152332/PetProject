package service

import (
	"log"
	"sort"
	"strings"
	"sync"
	"time"

	"petserver/internal/model"
	"petserver/internal/storage"
)

// 非接口类请求（官网页面、静态资源、后台 HTML、扫描探测）归入此 key，
// 避免统计里混入大量噪声；接口类只单独统计 /api/ 与 /download/
const otherMetricKey = "其他（页面/静态资源）"

// maxMetricKeys 接口 key 上限：路径由客户端决定，不设上限会被随机路径刷爆内存，
// 超限后新出现的接口统一并入 otherMetricKey
const maxMetricKeys = 300

// MetricsService 接口调用计数服务（纯内存累加 + 定期落盘）
//
// 隐私边界：只记录「哪个接口、成功还是失败、耗时」，
// 不记录查询参数、请求体、响应体、IP、主机名等任何可关联到用户的信息。
type MetricsService struct {
	mu    sync.Mutex
	stats map[string]*model.ApiMetric
	store *storage.ApiMetricsStore
	dirty bool      // 有未落盘的增量
	since time.Time // 计数起点（清零/首次启动）
}

// NewMetricsService 创建接口计数服务；store 为 nil 时退化为纯内存计数
func NewMetricsService(store *storage.ApiMetricsStore) *MetricsService {
	s := &MetricsService{
		stats: map[string]*model.ApiMetric{},
		store: store,
		since: time.Now(),
	}
	if store == nil {
		return s
	}
	loaded, since, err := store.Load()
	if err != nil {
		log.Printf("[metrics] 历史计数加载失败（本次从 0 开始）: %v", err)
		return s
	}
	for k, v := range loaded {
		v := v
		s.stats[k] = &v
	}
	if !since.IsZero() {
		s.since = since
	}
	if len(loaded) > 0 {
		log.Printf("[metrics] 已恢复 %d 个接口的历史计数（起点 %s）", len(loaded), s.since.Format("2006-01-02 15:04:05"))
	}
	return s
}

// keyOf 生成统计 key：接口类按 "METHOD /path" 独立统计，其余归入噪声桶
func keyOf(method, path string) string {
	if !strings.HasPrefix(path, "/api/") && !strings.HasPrefix(path, "/download/") {
		return otherMetricKey
	}
	return strings.ToUpper(method) + " " + path
}

// Record 记录一次调用。latencyUS 为处理耗时（微秒）
func (s *MetricsService) Record(method, path string, status int, latencyUS int64) {
	key := keyOf(method, path)

	s.mu.Lock()
	defer s.mu.Unlock()

	m, ok := s.stats[key]
	if !ok {
		if len(s.stats) >= maxMetricKeys {
			key = otherMetricKey
			m, ok = s.stats[key]
		}
		if !ok {
			m = &model.ApiMetric{Key: key}
			s.stats[key] = m
		}
	}

	m.Total++
	switch {
	case status >= 500:
		m.ServerErr++
	case status >= 400:
		m.ClientErr++
	default:
		m.Success++
	}
	if latencyUS < 0 {
		latencyUS = 0
	}
	m.LatencyUS += latencyUS
	if latencyUS > m.MaxLatencyUS {
		m.MaxLatencyUS = latencyUS
	}
	m.LastAt = time.Now().Format("2006-01-02 15:04:05")
	s.dirty = true
}

// Snapshot 返回统计总览，按调用次数倒序
func (s *MetricsService) Snapshot() model.ApiMetricOverview {
	s.mu.Lock()
	defer s.mu.Unlock()

	overview := model.ApiMetricOverview{
		GeneratedAt: time.Now().Format("2006-01-02 15:04:05"),
		SinceAt:     s.since.Format("2006-01-02 15:04:05"),
		Endpoints:   make([]model.ApiMetric, 0, len(s.stats)),
	}
	for _, m := range s.stats {
		item := *m
		if item.Total > 0 {
			item.AvgLatencyMS = float64(item.LatencyUS) / float64(item.Total) / 1000
			item.MaxLatencyMS = float64(item.MaxLatencyUS) / 1000
		}
		overview.Endpoints = append(overview.Endpoints, item)
		overview.TotalCalls += item.Total
		overview.ErrorCalls += item.ClientErr + item.ServerErr
	}
	sort.Slice(overview.Endpoints, func(i, j int) bool {
		a, b := overview.Endpoints[i], overview.Endpoints[j]
		if a.Total != b.Total {
			return a.Total > b.Total
		}
		return a.Key < b.Key
	})
	return overview
}

// Reset 清零计数并立即落盘
func (s *MetricsService) Reset() {
	s.mu.Lock()
	s.stats = map[string]*model.ApiMetric{}
	s.since = time.Now()
	s.dirty = true
	s.mu.Unlock()
	s.Flush()
	log.Printf("[metrics] 接口计数已清零")
}

// Flush 有增量时写盘（由定时任务与退出钩子调用）
func (s *MetricsService) Flush() error {
	if s.store == nil {
		return nil
	}
	s.mu.Lock()
	if !s.dirty {
		s.mu.Unlock()
		return nil
	}
	snapshot := make(map[string]model.ApiMetric, len(s.stats))
	for k, m := range s.stats {
		snapshot[k] = *m
	}
	since := s.since
	s.dirty = false
	s.mu.Unlock()

	if err := s.store.Save(snapshot, since); err != nil {
		log.Printf("[metrics] 计数落盘失败: %v", err)
		return err
	}
	return nil
}

// StartAutoFlush 定期落盘，避免高频请求逐个写文件
func (s *MetricsService) StartAutoFlush(interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for range ticker.C {
			_ = s.Flush()
		}
	}()
}
