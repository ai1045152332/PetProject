package model

// ApiMetric 单个接口的累计调用计数（按 "METHOD /path" 聚合）
// 只记录接口名、次数、状态码分类与耗时，不记录任何请求参数、内容或调用者身份
type ApiMetric struct {
	Key          string  `json:"key"`                    // 接口标识，如 "GET /api/devices"
	Total        int64   `json:"total"`                  // 累计调用次数
	Success      int64   `json:"success"`                // 2xx/3xx 次数
	ClientErr    int64   `json:"clientErr"`              // 4xx 次数
	ServerErr    int64   `json:"serverErr"`              // 5xx 次数
	LatencyUS    int64   `json:"latencyUs"`              // 累计耗时（微秒），用于算平均
	MaxLatencyUS int64   `json:"maxLatencyUs"`           // 最大单次耗时（微秒）
	AvgLatencyMS float64 `json:"avgLatencyMs,omitempty"` // 平均耗时（毫秒，快照时计算，不落盘）
	MaxLatencyMS float64 `json:"maxLatencyMs,omitempty"` // 最大耗时（毫秒，快照时计算，不落盘）
	LastAt       string  `json:"lastAt"`                 // 最近一次调用时间
}

// ApiMetricOverview 接口调用统计总览（后台展示用）
type ApiMetricOverview struct {
	GeneratedAt string      `json:"generatedAt"` // 本次快照时间
	SinceAt     string      `json:"sinceAt"`     // 计数起点（上次清零/首次启动时间）
	TotalCalls  int64       `json:"totalCalls"`  // 全部接口累计调用次数
	ErrorCalls  int64       `json:"errorCalls"`  // 全部 4xx/5xx 累计
	Endpoints   []ApiMetric `json:"endpoints"`   // 按调用次数倒序
}
