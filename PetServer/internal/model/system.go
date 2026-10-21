// Package model 系统状态数据结构
package model

// SystemStatus 服务器运行状态快照（后台监控页展示）
type SystemStatus struct {
	CPUPercent     float64   `json:"cpuPercent"`     // CPU 使用率 0~100
	Cores          int       `json:"cores"`          // CPU 核心数
	Load1          float64   `json:"load1"`          // 1 分钟负载
	Load5          float64   `json:"load5"`          // 5 分钟负载
	Load15         float64   `json:"load15"`         // 15 分钟负载
	MemTotal       uint64    `json:"memTotal"`       // 内存总量（字节）
	MemUsed        uint64    `json:"memUsed"`        // 已用内存（字节）
	MemUsedPercent float64   `json:"memUsedPercent"` // 内存使用率 0~100
	Hostname       string    `json:"hostname"`       // 主机名
	UptimeSeconds  int64     `json:"uptimeSeconds"`  // 系统运行时长（秒）
	Net            NetStatus `json:"net"`            // 网络流量
	VnstatDaily    []VnstatDay `json:"vnstatDaily"`  // vnstat 按天流量（最多 30 天，未安装则为空）
}

// NetStatus 网络流量（除 lo 外所有网卡汇总）
type NetStatus struct {
	RxBytes uint64 `json:"rxBytes"` // 累计接收字节数
	TxBytes uint64 `json:"txBytes"` // 累计发送字节数
	RxRate  uint64 `json:"rxRate"`  // 接收速率（字节/秒）
	TxRate  uint64 `json:"txRate"`  // 发送速率（字节/秒）
}

// VnstatDay vnstat 按天流量统计
type VnstatDay struct {
	Date string `json:"date"` // 日期 YYYY-MM-DD
	Rx   uint64 `json:"rx"`   // 接收（字节）
	Tx   uint64 `json:"tx"`   // 发送（字节）
}
