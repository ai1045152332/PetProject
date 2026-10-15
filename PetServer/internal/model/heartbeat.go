// Package model 定义 PetServer 的数据模型
package model

import "time"

// Heartbeat 宠物 App 每 1 分钟上报的本机简单信息
type Heartbeat struct {
	Version  string `json:"version"`  // App 版本号
	Hostname string `json:"hostname"` // 主机名
	OS       string `json:"os"`       // macOS 版本
	Machine  string `json:"machine"`  // 机器架构
	PetName  string `json:"petName"`  // 宠物名称
	PetState string `json:"petState"` // 宠物当前状态（focus/idel/warn/sleep/pet）
}

// Validate 校验必填字段，返回第一个缺失字段名；全部有效时返回空串
func (h *Heartbeat) Validate() string {
	switch {
	case h.Version == "":
		return "version"
	case h.Hostname == "":
		return "hostname"
	case h.OS == "":
		return "os"
	case h.Machine == "":
		return "machine"
	case h.PetName == "":
		return "petName"
	case h.PetState == "":
		return "petState"
	default:
		return ""
	}
}

// Device 设备记录：某台设备最近一次心跳及到达时间
type Device struct {
	Heartbeat
	LastSeenAt time.Time `json:"lastSeenAt"`
}

// DeviceView 设备在线视图：附带在线状态、距今秒数，供 H5 列表展示
type DeviceView struct {
	Heartbeat
	LastSeenAt string `json:"lastSeenAt"` // 最近心跳时间（RFC3339）
	SecondsAgo int64  `json:"secondsAgo"` // 距最近心跳的秒数
	Online     bool   `json:"online"`     // 是否在在线阈值内
}
